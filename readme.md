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
| tunnel.sh | yes | self-healing ssh tunnel to the remote 3-node model (retries forever) |
| qwen-remote.sh | yes | qwen-code against the remote model via the tunnel (knobs: REMOTE_MODEL, COMPACT) |
| qwen-super.sh | yes | crash-proof supervisor for unattended qwen-remote runs (health-gate + relaunch-until-DONE) |
| health-remote.sh | yes | check the remote model through the tunnel |
| tokenize.sh | yes | show how the remote model tokenizes the argument |
| remote/ | yes | reference copies of the remote big-model server scripts: serve.sh, serve-new.sh (tuned, +MTP), serve-rpc.sh + start-rpc.sh (multi-node RPC, current production), rpc.md (step-by-step RPC runbook), qwen.sh, health.sh |
| llama | yes | tiny launcher; libs load via RUNPATH from the POC build dir `/data/ai/local-agent-poc/src/llama.cpp/build-vulkan/bin` — keep that dir |
| readme.md | yes | this file |
| asgard/ | yes | **second box** (Dell Precision 7750: Xeon W-10885M, Quadro RTX 5000 16 GiB, 128 GiB DDR4, FreeBSD 15.1-STABLE): `asgard/plan.md` = hardware budget, tiered model shortlist (T-1/T0/T1/T2), configs, native Vulkan build incl. the clang-21 trap, test protocol, status; `asgard/research/*.md` = the raw research reports behind it (+ the `test-backend-ops` excerpt), `asgard/vkalloc.c` = the pinned-cap probe; **asgard variants of the scripts** (like local / remote / rpc before): `asgard/models.sh` (per-model file, HF rev, sha256, spec-type, cache-ram, sampling, thinking toggle), `asgard/serve.sh MODEL`, `asgard/download.sh MODEL`, `asgard/health.sh`, `asgard/qwen.sh` (`MODEL=…`), `asgard/bench.py`, `asgard/rust-test.sh MODEL` (the full test: qwen-code writes+tests a Rust string reverser, verified independently); `asgard/ops.md` = **how llama-server is run** (start/stop, the `service llama` stub → `asgard/llamactl.sh`, thermal-watchdog suspend hooks, zzz/resume contract, stall detector — settled 2026-09-12); `asgard/start.sh` / `stop.sh` / `llamactl.sh` / `rc.d/llama` (stub source) / `unstick.sh` (stall detector + watchdog hooks) / `zzz-probe.sh` (S3 probe) / `sweep.sh`, `e2e-*.sh`, `verify-*.sh` (the spec/fit sweeps and the four-task E2E harness, see results-t1.md); `asgard/status-2026-09-11.md` = end-of-groundwork report, `asgard/results-t1.md` = T-1 download/test log |
| model.gguf | no (.gitignore) | Qwen3-Coder-30B-A3B-Instruct Q8_0, 30.25 GiB |
| key.secret | no (.gitignore) | API key the server requires and clients send |
| remote-host.secret, remote-key.secret | no (.gitignore) | remote main node ssh target + its API key |

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
build. Idle stack costs ~0 CPU/disk; RAM: helper tensors are anonymous +
swapless = pinned hot forever, while the main's mmap'd weights auto-evict
under memory pressure — see remote/rpc.md "Idle cost" for why there is no
freeze-to-disk middle ground. Measured penalties vs single-node (same
hardware class): big models
~**-5% generation, prompt processing unchanged**; small models suffer more
(7B ~-15%, 1.5B ~-33%) — the fixed ~1-3 ms/token network cost dominates only
when per-token compute is tiny. Rule: RPC-split only models that do NOT fit
on one box.

Current production default in serve-rpc.sh: **Ornith-1.5-397B Q8_0**
(428.5 GB, qwen35moe MoE, A17B, SWE-bench-Verified 86.0) split across
3× 256 GB nodes — 4 parallel slots, YaRN knob `YARN=1` default since
2026-09-09 (native 262144 ctx/slot, max quality — overnight runs never passed
~53K; `YARN=2` = 524288/slot ~lossless, `YARN=4` = 1M/slot with softer
long-range recall; hybrid linear
attention keeps KV at ~4 KB/token ⇒ all modes afford 4 slots), f16 KV,
ngram-mod speculation, sampling per model card (temp 0.6 / top-p 0.95 /
top-k 20). Historical single-node modes (serve.sh, serve-new.sh) stay
available unchanged.

**Generation speed decays with context depth** (measured 2026-09-08: tg
3.0 t/s @24K → 1.34 @53K; extrapolates to ~0.4-0.5 t/s at the full 256K —
no floor, tg ≈ 1/(a+b·depth)). **Policy: COMPACT default 0.9-0.95; optional
speed setting allowed, never below 0.5** — compaction is lossy summarization
and we choose full-context quality; if depth-decay hurts even at 0.5 the fix
is a faster model/rig, not deeper compaction.
Server knobs `FA=on KVQ=q8_0` and `THREADS=24` were A/B/C-benched 2026-09-09
and **lost to the defaults** (CPU flash-attn halves-to-thirds prefill; T24
drops tg at most depths) — keep FA/KVQ off, THREADS=16; numbers in
remote/rpc.md "Generation speed vs context depth".

**Unattended runs must use qwen-super.sh** (2026-09-08 lesson: a home↔Linode
network flap killed the raw qwen process mid-task; the tunnel self-healed but
the client never came back). Three layers now: maxRetries 5000 in
qwen-remote.sh (SDK retries between-request failures ~11 h), qwen-super.sh
relaunches after mid-stream kills with REAL session resume (`qwen -c`, chat
recording is on by default) plus health-gating and a DONE-file stop, and a
workspace-state fallback prompt when no session exists — see remote/rpc.md
"Unattended / overnight runs".

**NEXT MODEL (planned upgrade)**: **GLM-5.3-Flash Q8_0** (341 GB, TRUE 1M
native context, 320B-A18B, reasoning-effort control) as soon as llama.cpp
**PR #27754** (`glm5_next` arch, by Unsloth) merges to master. Status
2026-09-09 (checked via gh): still OPEN, but the long-context repeating-token
collapse was root-caused to a **Metal-only** int32 overflow (`mul_mm.metal`
batched dst offset past 2^31) — "CPU-only at the same failing depth is fine",
so it does NOT block this all-CPU rig. Remaining agent-blocker: the branch
serves `supports_tool_calls=false` (chat-template gap) — useless for qwen-code
until fixed. Perf outlook vs Ornith at equal Q8: similar (A18B vs A17B); the
real wins would be TRUE 1M ctx (no YaRN) and community-validated smaller
quants (unsloth UD-IQ4_XS ~147 GB → fits ONE node, no RPC hops; reported
several-x tg vs Q8 on CPU). Re-check the PR every week or two.

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

## asgard (second box, 2026-09-11) — see asgard/plan.md

Dell Precision 7750 (Xeon W-10885M 8C/16T, **Quadro RTX 5000 16 GiB** on
nvidia 595 + Intel P630 iGPU for X, 128 GiB DDR4-2933, 4-way NVMe mirror,
GELI). Same repo checked out at `/data/local-ai`; same POC tree at
`/data/ai/local-agent-poc`; `zroot/data/local-ai` dataset with the same
`compression=off primarycache=metadata` recipe (`/data/ai` is a plain dir) and
`vfs.zfs.arc.max=17179869184` (16 GiB) in `/etc/sysctl.conf` — with 128 GiB and
no cap the ARC reached 88 GiB and the NVIDIA driver's pinned host allocations
(what `--n-cpu-moe` experts live in) failed outright (asgard/results-t0.md §3.2).
Status: llama.cpp v0.4.0 built natively with Vulkan, Quadro visible as
`Vulkan0` with NV_coopmat2, `test-backend-ops` gate: 0 FAIL over every op
(the full run only aborts at one synthetic 768 MiB upload — the driver cap
below, not a kernel bug). Models: `/data/local-ai/models/*.gguf` (gitignored,
on the dataset), fetched one at a time with `asgard/download.sh MODEL` and
each put through the full test before the next download — see
`asgard/results-t1.md`; the consolidated T-1 report (winner `qwen35b`, scoreboard, incidents, frozen config) is
**`asgard/report-t1.md`**. Everything else, incl. the ranked shortlist (T-1
North-Mini-Code / Qwen3.5-9B / Gemma-4-26B-A4B, T0 Qwen3.6-35B-A3B, T0b
KAT-Coder, T1, T2 Qwen3.8-Flash-Next), is in `asgard/plan.md`; the
end-of-groundwork report is `asgard/status-2026-09-11.md`.

Serving on asgard: `asgard/serve.sh` (default `qwen35b` = the frozen T-1
`fastest-vram` winner, Qwen3.6-35B-A3B UD-IQ2_M; T0 candidates `qwen35b-q4` /
`kat-q4` / `qwen35b-q8`; `NP=` slots, `THREADS=`, `NCMOE=` overrides) — same
`10.253.254.1:18080` + alias `qwen3coder-local` as tuxi, so the top-level
`qwen.sh`/`health.sh`/`copilot.sh` also work there; `MODEL=qwen35b
asgard/qwen.sh` adds the model's own sampling. T-1: all weights + 256K q8_0 KV
in Quadro VRAM (`--gpu-layers 99 --device Vulkan0`, X on the iGPU); T0 adds
`--n-cpu-moe N` (expert layers in CPU RAM). The other T-1 candidates (North,
Qwen3.5-9B, Gemma-4) were removed on 13 Sep 2026 — see `asgard/report-t1.md` §8.

Running it (2026-09-12, settled in **`asgard/ops.md`**): `asgard/start.sh MODEL`
(daemonizes serve.sh, waits for `/health`, remembers the start in
`~/local-ai-runs/last-start.env`; `--last` replays it) / `asgard/stop.sh`, or the
service form `sudo service llama start [MODEL]|stop|restart|status` —
`/usr/local/etc/rc.d/llama` is a stub (`KEYWORD: nostart`, never in the boot
sequence) whose commands call `asgard/llamactl.sh`, so only files in this repo
change. Contract: **you** start/stop llama; a normal `zzz`/poweroff does nothing
with it; **only the thermal watchdog's suspend action** stops the server right
before S3 (TERM, KILL after 3 s) and restarts it after the resume if it was
running (`asgard/unstick.sh pre-suspend` / `post-resume`, wired as
`WD_SUSPEND_PRE/POST` in `thermal-policy.conf`); its power-off action stops
nothing. `unstick.sh check|fix|watch|kill|show` is the stall detector (slot
processing + GPU 0 % for 60 s → kill -9 + restart by provenance) that
`asgard/e2e-test.sh` runs alongside every task, continuing the qwen session
(`qwen -r SID`) after an API error. `asgard/zzz-probe.sh` is the S3 probe that
found the hang. Log: `~/local-ai-runs/unstick/unstick.log` + syslog tag `unstick`.

Rules learned on asgard:

- **FreeBSD nvidia 595 Vulkan pinned-memory cap**: one host-visible
  allocation must be < 256 MiB (`VK_ERROR_OUT_OF_DEVICE_MEMORY` at exactly
  256 MiB; total pinned and device-local are unlimited — probe:
  `asgard/vkalloc.c`). ggml-vulkan stages every `tensor_set/get` through one
  buffer of the copy's size, so: **always `--load-mode none`** (the default
  mmap path uploads whole tensors — `output.weight` of a 9B Q8_0 is 1 GiB),
  never `--check-tensors`, never `GGML_VK_PREFER_HOST_MEMORY`, and
  `--cache-ram 0` for models whose K or V per layer exceeds 255 MiB at the
  context size (Qwen3.5-9B, Gemma 4 at 262K; MoE 35B/North are fine).
  Details and the arithmetic: `asgard/plan.md` §6.
- **S3 with GPU work in flight hangs llama-server for good** (live test
  2026-09-12 07:26, `sudo zzz` mid-generation, resumed after 93 s): the process,
  `/health` and `/slots` stay alive but the main loop sleeps forever in
  `ggml_vk_wait_for_fence → libnvidia-eglcore poll()` on a fence submitted before
  the suspend — GPU 0 % / 300 MHz, VRAM held, SIGTERM ignored (KILL needed), no
  device-lost from the 595.99.02 driver, fresh Vulkan contexts work, the client
  waits silently. Hence: **stop the server before your own `zzz`** (1–2 s;
  ~6 s warm reload) — the thermal watchdog's suspend does that by itself
  (`asgard/ops.md` §3); the in-flight request is lost either way and a deep
  session re-ingests (128K ≈ 7 min with `--cache-ram 0`). Whether an *idle*
  server's VRAM survives S3 is untested (`zzz-probe.sh pre/zzz/post`).
- **`asgard/health.sh` sends a real completion** — never run it while a task
  is in flight: with NP=1 it queues behind the task and then evicts its KV cache
  (a 150K E2E context = ~7 min to re-ingest). `llamactl.sh status` (= `service
  llama status`) and `unstick.sh` use only `/health`, `/props`, `/slots`.
- **`--spec-type draft-mtp` only with `*-MTP-GGUF` files**: on a model
  without MTP layers llama-server exits at start (`failed to create MTP
  context`); use `ngram-mod` alone for North-Mini-Code / KAT-Coder / Gemma 4.
- **clang 21 trap**: 15.1-STABLE ships clang 21.1.8, which needs > 40 min
  (killed at 42) for `ggml/src/ggml-vulkan/ggml-vulkan.cpp` at `-O3`
  (register allocation blows up on `ggml_vk_load_shaders`); tuxi's clang
  19.1.7 does it in 127 s. Fix in the POC: `bin/cxx-launcher.sh`
  (`CMAKE_CXX_COMPILER_LAUNCHER`, auto-enabled by `bin/01b-build-vulkan.sh`
  when `cc -dumpversion` ≥ 21) rewrites `-O3`→`-O2` for that one TU (151 s);
  it is host-side Vulkan glue, inference speed is unaffected. Decision: keep
  base clang 21, do **not** install `llvm19`.
- Do not sync `build-vulkan/` or `build-cpu/` between the laptops:
  `-march=native` binaries from tuxi (Zen 4) SIGILL on asgard (Comet Lake,
  no AVX-512 either way but different ISA extensions) — rebuild in place.
- Turbo is disabled in asgard's BIOS → 2.4 GHz cap; with the default
  `hwpstate_intel` epp=100 cores sit at ~1.5 GHz under load. For builds and
  CPU-offload grids use `sysctl dev.hwpstate_intel.{0..15}.epp=0` (runtime
  only) and restore 100 afterwards.
- Never `zzz` with a model mmap-loaded from the `primarycache=metadata`
  dataset (cold re-read on resume); asgard has GELI, so a GPU hang means a
  passphrase at the console — never run GPU `llama-bench` there either.
