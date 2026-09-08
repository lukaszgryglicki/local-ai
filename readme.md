# local-ai

Fully local coding-agent stack on a FreeBSD laptop: Qwen3-Coder-30B (256K
context) served by llama.cpp/Vulkan, driven by qwen-code on the host and
GitHub Copilot CLI from a bhyve VM. No cloud inference; a full multi-hour
agent session costs ~0 (a few cents of electricity, 0 premium requests).

## Hardware / OS

- AMD Ryzen 7 8845HS (8c/16t Zen 4), Radeon 780M iGPU (RDNA3), 61.75 GiB
  DDR5, NVMe (~700 MB/s cold read), FreeBSD 15.1, ZFS, no swap.
- iGPU: BIOS VRAM carve-out is only 2048 MiB; the ~21.9 GiB "device-local"
  heap RADV reports is carve-out + GTT (shared system RAM, ~31.6 GiB budget).
  Every GPU byte is a wired host-RAM byte at the same DDR5 speed.
- bhyve Ubuntu VM exists for exactly one thing FreeBSD cannot run: GitHub
  Copilot CLI. The ports/pkg binary is a Linux ELF that fails on the host
  ("Program headers not in the first page" / Exec format error) and the
  genuine linux-x64 binary under Linuxulator launches but hangs at first
  real use. Everything else (server, model, qwen agent) runs on the host.
  Host FS is mounted in the VM at /freebsd; server is reached over the
  bhyve bridge (10.253.254.1).

## Files

| file | tracked | what |
|---|---|---|
| serve.sh | yes | start the model server (final tuned config) |
| health.sh | yes | check server is up AND generates (auth round-trip) |
| qwen.sh | yes | qwen-code agent against the local model (host) |
| copilot.sh | yes | GitHub Copilot CLI + local model (run in the VM) |
| remote/ | yes | reference copies of the remote big-model server scripts: serve.sh, serve-new.sh (tuned, +MTP), serve-rpc.sh + start-rpc.sh (multi-node RPC, current production), rpc.md (step-by-step RPC runbook), qwen.sh, health.sh |
| llama | yes | tiny launcher; libs load via RUNPATH from the POC build dir `/data/ai/local-agent-poc/src/llama.cpp/build-vulkan/bin` — keep that dir |
| readme.md | yes | this file |
| model.gguf | no (.gitignore) | Qwen3-Coder-30B-A3B-Instruct Q8_0, 30.25 GiB |
| key.secret | no (.gitignore) | API key the server requires and clients send |

Server binary is a llama.cpp fork build (LLAMA_REF v0.4.0), Vulkan backend.

## Model & sizing

- Qwen3-Coder-30B-A3B-Instruct, Q8_0 GGUF: MoE with ~3B active params per
  token — the sweet spot for CPU+iGPU boxes (expert FFNs run on CPU where
  only the active experts are touched).
- Hard requirement: 262144 (256K) context for agent workloads.
  KV cache q8_0/q8_0 + flash-attn = 12.75 GiB (f16 would be 24 GiB — does
  not fit next to 30.25 GiB weights). Server RSS ~43 GiB total.
- parallel=1: two 256K slots would need ~58 GiB (> ~55 available) — cannot
  fit. One client at a time; a second concurrent client just queues.
- Load time ~45-60 s (cold NVMe read).

## Final server config (serve.sh)

`--gpu-layers 99 --cpu-moe --no-kv-offload` = attention weights on iGPU
(GTT), expert FFNs + KV cache + all attention compute on CPU/RAM.
Plus: `--ctx-size 262144 --parallel 1 --cache-type-k/v q8_0 --flash-attn on
--batch-size 2048 --ubatch-size 1024 --threads 12 --spec-type ngram-simple`,
sampling at Qwen recommendations (temp 1.0, top-p 0.95, top-k 20).
Logs: stdout AND `/tmp/local-ai-llama.log` (--log-file).

## Measured performance (full 256K ctx enabled)

First working config: input 68.5 tok/s, output 1.6 tok/s. Final config:

- Prompt processing: 330 tok/s shallow, depth-decaying to ~165 avg over a
  24K-token prompt; 121-135 on typical 20K agent prompts; 280+ on cached
  follow-ups. Copilot-style prompts measured 203-227.
- Generation: 10.5-11.4 tok/s shallow; ~4.7-5 fresh text at 20-24K depth;
  12-35 on echo-heavy output (file edits) thanks to ngram speculation.
- Real agent session average (91-min copilot task, 57 requests):
  input 84.8 tok/s, output 7.53 tok/s, ngram draft acceptance 71-74%,
  busy time 94% generation.

## Performance laws (all measured on this box, 2026-09-06)

1. **SMT kills generation**: t16 = 1.37 tok/s vs t8 = 10.99 (the original
   "1.6 tok/s output" was mostly this). Never let threads autodetect to 16.
   t8/t10/t12 shallow are equal within noise (11.33/11.36/11.09); t12 was
   +19% at 16K depth in bench, a wash in real serving. Using t12.
2. **ubatch scales input only** (generation is batch=1): server pp
   83.6 → 100 → 121 tok/s at ub 256 → 512 → 1024. **ub2048 = instant
   DeviceLost at 256K warmup** — hard cliff, do not use.
3. **256K GPU-attention law**: any layout where the GPU touches KV or
   attention dies — KV-on-GPU aborts at init from 32K ctx up (despite pp
   350/tg 11.6 at small ctx); ngl=0 with op-offload DeviceLosts once depth
   reaches ~64K; no GGML_VK_* env knob fixes it. Only
   ngl99+cpu-moe+nkvo is 256K-safe: the GPU per-submit working set is
   weights-only, depth-independent.
4. **Depth decays CPU-attention generation**: bench single-stream tg
   11.16 @0 → 5.69 @4K → 2.17 @16K (server does better; see numbers above).
5. **ngram-simple self-speculation is a free win**: lossless, zero extra
   RAM, drafts from prompt/history n-grams, batch-verified. 71-74%
   acceptance across real coding sessions ≈ roughly 2x effective output;
   echo tasks (project-file edits) hit 34.6 tok/s with 100% acceptance.
   Works with q8 KV via checkpoint mode in this fork.

## Speculative decoding upgrades: ngram-mod + MTP (remote/serve-new.sh)

A dedicated tuning pass on the remote big-MoE server found two lossless
generation-speed upgrades; both are generic llama.cpp features worth
knowing about beyond that box:

- **ngram-mod** (`--spec-type ngram-mod`): rolling-hash self-speculation
  (~16 MB state), a strict upgrade over ngram-simple there — never worse
  than baseline, up to ~2.6x on edit/repeat-heavy agent turns.
- **MTP draft head** (`--spec-type draft-mtp`): some model families ship a
  small companion multi-token-prediction GGUF (a single extra decoder
  block, ~2.4 GB at Q4_K_M). It drafts a few tokens ahead; the main model
  batch-verifies them — output distribution mathematically unchanged.
  Measured: +20-25% on NOVEL generation (where ngram methods get nothing;
  draft acceptance 0.85-0.91, matching the head author's GPU numbers),
  cost ~5% slower prompt processing.
- **Best: both combined** — MTP covers novel text, ngram-mod covers
  repeats: `--model-draft <mtp-head.gguf> --spec-type draft-mtp,ngram-mod
  --spec-draft-n-max 6 --spec-draft-p-min 0.75`
  (+ env `LLAMA_ATTN_ROT_DISABLE=1` when using quantized q8_0 KV).
  remote/serve-new.sh wires this up and auto-falls back to plain
  ngram-mod when the head or the MTP-capable binary is absent.
- Caveat: stock llama.cpp v0.4.0 lacks the MTP graph for that model
  family (upstream PR closed unmerged); the remote build carries a small
  port of it. Q4_K_M head measured as good as BF16 at a third of the RAM;
  draft depth 6 beat depth 3 on repeats at equal cold-gen speed.
- Host note: this box's serve.sh stays on ngram-simple (71-74% acceptance
  measured here, and no MTP head exists for its model). ngram-mod is worth
  a try on the host someday, but it is untested against the Vulkan
  pipeline — verify against the real server first (see rules below).


## Multi-node RPC serving (remote/serve-rpc.sh + remote/start-rpc.sh)

Step-by-step start/stop runbook (helpers → main server → tunnel → qwen):
see **remote/rpc.md**.

llama.cpp's GGML RPC backend splits ONE model's layers across several boxes
over a private LAN: helpers run `start-rpc.sh` (a bare `ggml-rpc-server`,
RAM+CPU donor, no model file needed — tensors re-stream in at every load;
no disk cache: measured ~4 min saving on a ~44 min load for ~248 GB written),
the node holding the .gguf runs `serve-rpc.sh` which auto-discovers helpers
and serves the usual single OpenAI endpoint. Requires a `-DGGML_RPC=ON`
build. Measured penalties vs single-node (same hardware class): big models
~**-5% generation, prompt processing unchanged**; small models suffer more
(7B ~-15%, 1.5B ~-33%) — the fixed ~1-3 ms/token network cost dominates only
when per-token compute is tiny. Rule: RPC-split only models that do NOT fit
on one box.

Current production default in serve-rpc.sh: **Ornith-1.5-397B Q8_0**
(428.5 GB, qwen35moe MoE, A17B, SWE-bench-Verified 86.0) split across
3× 256 GB nodes — 4 parallel slots, YaRN knob `YARN=2` default (524288
ctx/slot, ~lossless 2x over the 262144 native; `YARN=1` = native max
quality, `YARN=4` = 1M/slot with softer long-range recall; hybrid linear
attention keeps KV at ~4 KB/token ⇒ all modes afford 4 slots), f16 KV,
ngram-mod speculation, sampling per model card (temp 0.6 / top-p 0.95 /
top-k 20). Historical single-node modes (serve.sh, serve-new.sh) stay
available unchanged.

**NEXT MODEL (planned upgrade)**: **GLM-5.3-Flash Q8_0** (341 GB, TRUE 1M
native context, 320B-A18B, reasoning-effort control) as soon as llama.cpp
**PR #27754** (`glm5_next` arch, by Unsloth) merges to master — as of
2026-09-08 the PR still has an unresolved long-context repeating-token
collapse bug (65-253K depth, Metal+CUDA), so building the PR branch early
was rejected; re-check the PR every week or two.

## ZFS: why the model has its own dataset

This dir = dataset `zroot/data/local-ai` with `primarycache=metadata`,
`compression=off`. Without it every model load double-buffered 30 GiB into
ZFS ARC (mmap and plain read() alike; O_DIRECT silently falls back on
unaligned reads), free RAM collapsed and the box OOM-froze mid-load.
With it ARC stays flat. model.gguf here is the real file (BRT block-clone);
the POC path symlinks to it.

## Agent clients

### qwen.sh (host)

qwen-code CLI in a throwaway HOME (generated settings.json), pointed at the
local server; variables/keys from key.secret; internet tools enabled.
One mandatory exclusion: `report_findings` — this build's JSON-schema→GBNF
grammar converter 400s on that tool's schema (maxLength inside a maxItems
array) on EVERY request. Copilot's toolset does not trigger the bug.
`timeout 7200000` and `max_tokens 8192` are per-REQUEST/turn caps, not
session caps: with ~99% prompt-cache reuse the worst realistic call (cold
full-256K prompt + 8192 out) ≈ 63 min < 2 h; sessions are unbounded.

### copilot.sh (bhyve VM, this dir = /freebsd/data/local-ai)

Runs your normal copilot (real HOME: GitHub login, MCP, all cloud models
still selectable via /model) and merely ADDS the local provider via
COPILOT_PROVIDER_TYPE/BASE_URL/API_KEY env + `--model qwen3coder-local`
preselected. Sessions on the local model consume 0 premium requests.

## Validation (all green, 2026-09-06)

- API smoke + one-shots: PASS (qwen host, copilot VM).
- qwen full task test (Go HTTP handler + slug pkg + tests, external
  verifier): PASS. Independent code review: solid mid-level Go, ~90% spec
  conformance, genuinely good table-driven tests, one latent bug
  (unicode.IsDigit accepts non-ASCII digits).
- copilot-from-VM task test: PASS, zero tool exclusions needed.
- Complex e2e (copilot YOLO/autopilot, local model): fetch iris.csv with
  curl, verify it, build a 3-subcommand CSV-stats CLI in Go with tests,
  iterate `go vet`/`go build`/`go test` to green. ~91 min wall, 57
  requests, 29.7K tok in / 38.9K out. All functional acceptance outputs
  byte-exact vs precomputed ground truth. ONE human nudge needed: its unit
  test compared a "%.3f" string to the raw float (4.083 vs 4.083333) — and
  its final report claimed `go test` was green when it wasn't. Lesson:
  always re-run the acceptance battery yourself after "task complete".
- Cutoff artifact: hand-writes `go 1.19` in go.mod instead of running
  `go mod init` (harmless — it's a minimum, not a pin).

## Cost reality check

The 91-min session ≈ 0.1 kWh ≈ 2-4 cents of electricity, 0 API tokens,
0 premium requests. The same agent loop at cloud API prices (context
resubmitted every turn ⇒ ~1.4M input tokens): ~$5-25 uncached, ~$1-7 with
prompt caching, depending on model class. Trade-off: 7.5 tok/s output vs
~60-80 in the cloud.

## Ops

FreeBSD host:

    ./serve.sh          # ready when "listening on http://10.253.254.1:18080"
    ./health.sh         # up + generates
    ./qwen.sh           # interactive; or ./qwen.sh -p "task"

bhyve VM:

    ./copilot.sh        # interactive; or ./copilot.sh -p "task"

Stop server:

    kill $(pgrep -f local-ai/llama)

Rules learned the hard way:

- parallel=1: run ONE client at a time (second one queues silently).
- Do NOT run llama-bench GPU probes on this box: `-t 12,16` with
  GPU-resident weights hard-hung the whole machine twice (power-cycle).
  Test config changes against the real server only.
- Server-side DeviceLost (e.g. ub2048 experiment) does not hang the host —
  it just kills the server; safe to retry with fixed settings.
