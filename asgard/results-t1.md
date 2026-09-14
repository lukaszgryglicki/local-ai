# asgard T1 results — the `fast` profile (VRAM + iGPU/RAM overflow), started 2026-09-12 21:52

Companion to `plan.md` (§4 shortlist, §10 profiles and speed goals) and `report-t0.md` / `results-t0.md` (the T0 phase this
continues). Same box, same regime, same harness: Dell Precision 7750, Quadro RTX 5000 16 GiB = Vulkan0, Intel UHD P630 =
Vulkan1 (Mesa ANV, 95.7 GiB UMA heap), 128 GiB DDR4, FreeBSD 15.1, llama.cpp POC fork v0.4.0 `5266f24` **`build-vulkan-2`**
(chunked staging transfers, `patches/0001-…`), "turbo band" thermal policy, BIOS Cool, EPP 100. Hard requirements as in T0:
native 262 144 context per slot, thinking on, q8_0 K/V, flash attention, no YaRN, model-card sampling.

**T1 definition (owner, 12 Sep 11:14–11:24, plan §10)**: `fast` = VRAM first, the overflow to the **iGPU (Vulkan1) or CPU
RAM — whichever measures faster**; no OOM, no "slow-token" regime. Goal **≥ 6 t/s output (session aggregate), absolute
minimum 4, ideal 7–10**. The model is again chosen by the four-task E2E; speed is the constraint. (The plan's earlier
"≤ 30 % of experts in RAM" rule is superseded by the speed goal.) Verdict vocabulary as before: PASS / FAIL-task /
FAIL-infra.

The knobs (all in `serve.sh`, per-model defaults in `models.sh`): `NCMOE=k` = `--n-cpu-moe k` (expert tensors of the first k
layers in CPU RAM; for prompt batches ≥ 32 tokens ggml uploads them to the Quadro per micro-batch, so prompt processing
stays on the GPU); `IGPU_MOE=k` = the same tensors in Vulkan1 device memory via
`--override-tensor 'blk.(0|…|k-1).ffn_(up|down|gate)_exps.weight=Vulkan1'` (they are then computed *by the iGPU* for
prompts and generation alike). Everything else — attention, embeddings, output, the 256K KV, compute buffers — stays on
the Quadro.

## 0. Candidates and downloads (queue started 21:52, one file at a time, ~9.7 MB/s on wlan0)

| name | model / file | GiB | why |
|---|---|---|---|
| `qwen35b-q4` | Qwen3.6-35B-A3B **UD-Q4_K_XL** (unsloth, non-MTP) @ `a483e9e` | 20.8 | the T0 winner at a real 4-bit: same behaviour, quantisation risk gone; plan estimate 20 of 40 expert layers off VRAM |
| `kat-q4` | **KAT-Coder-V2.5-Dev Q4_K_L** (bartowski, imatrix) @ `d8f684f` — Kwaipilot's agentic-coding RL fine-tune of Qwen3.6-35B-A3B, thinking kept, no MTP head | 20.3 | the coding specialist of the class; head-to-head with `qwen35b-q4` at equal size |
| `qwen35b-q8` | Qwen3.6-35B-A3B **Q8_0** (unsloth, non-MTP) @ `a483e9e` | 34.4 | the quality reference; ~29 expert layers off VRAM — is Q8 still inside the T1 goal? If not it is T2 material |

Not queued (yet): the MTP-repo files (the T0 sweep showed n-gram speculation costs 17 % on this MoE, and with experts in
RAM every verified draft token pays the expert loads again — to be tested only if a T1 winner has speed to spare);
UD-Q5/Q6 (between Q4 and Q8 — only if Q8 misses the goal and Q4 has large headroom); Qwen3.6/3.8-27B dense (the FFN of a
dense model in RAM would run ≈ 3–4 t/s — below the T1 floor); everything ≥ 122B (T2).

## 1. iGPU vs CPU RAM — the placement question, answered first (22:00, `qwen35b` UD-IQ2_M, 20 of 40 expert layers moved)

Measured before any T1 file arrived, with the T0 winner's file, `sweep.sh qwen35b "cpu20=none;;NCMOE=20"
"igpu20=none;;IGPU_MOE=20"` (codebench: 2 coding prompts, thinking on, greedy, 2 048 tokens each; all-VRAM reference from
the 16:38 sweep):

| placement of 20 expert layers | VRAM | pp t/s (48–52-token prompts) | tg t/s (2 × 2 048 tokens) | vs all-VRAM |
|---|---|---|---|---|
| all 40 in VRAM (reference) | 14 099 MiB | — | **61.3 / 56.4** | 1.00 |
| **CPU RAM** (`NCMOE=20`, 8 threads) | 9 601 MiB | **102.9** | **30.4** | 0.50 |
| **iGPU** (`IGPU_MOE=20`, Vulkan1) | 9 504 MiB | **5.7 / 7.0** | **14.5 / 14.5** | 0.24 |

- **CPU RAM wins by 2.1× on generation and ~15× on prompt processing.** The iGPU (24 EUs, no int-dot, no matrix cores,
  Mesa ANV) computes the expert matmuls itself, and unlike host-resident weights its buffers never take ggml's
  "upload the weights to the big GPU for this batch" path, so *every* prompt token runs on the P630. Generation on it is
  compute-bound at ≈ 4 GB/s of effective weight traffic. Result for the owner's rule: **overflow goes to CPU RAM**;
  `IGPU_MOE` stays available in `serve.sh` (re-checked once on the Q4 file below, then retired).
- `--split-mode none` cannot be used with `--override-tensor …=Vulkan1`: llama.cpp prunes the model's device list to
  `main-gpu`, the Vulkan1 buffer has no backend in the scheduler and the server aborts at load (`pre-allocated tensor
  (blk.0.ffn_down_exps.weight) in a buffer (Vulkan1) that cannot run the operation`). `serve.sh` now uses
  `--split-mode layer --tensor-split 1,0` (fixed 22:00; the earlier form had never been exercised).
- Cost model from this run (IQ2_M): 20 layers of experts = 4.5 GiB of VRAM (0.225 GiB/layer); on the CPU the same 20
  layers cost ≈ 17 ms per token (30.4 vs 61.3 t/s) — ≈ 14 GB/s effective, i.e. dequant/compute-bound at 8 threads on
  AVX2, not DDR4-bound (≈ 40 GB/s) — *or so it seemed*: **thread count changes nothing** (22:10, same config:
  `THREADS=16` 31.3 t/s, `THREADS=8` 30.4, `THREADS=4` 29.1). With 4 threads as fast as 16 and the traffic at ≈ 7 GB/s,
  the CPU path is neither compute- nor bandwidth-bound; it is **split/synchronisation-bound**: every offloaded layer
  costs a GPU→host copy, a CPU graph split and a host→GPU copy with fence waits (2k+1 scheduler splits per token),
  ≈ 0.85 ms per offloaded layer here. Consequences for T1/T2: the price of offloading scales with the **number of
  layers** whose experts leave VRAM, much less with their bytes → fill VRAM to the last expert layer (the fit ladder's
  minimum k), expect Q8_0 layers to cost about the same per layer as IQ2_M ones, and leave `--threads 8`.
- **Prompt processing is unaffected by the offload** (22:17, `bench.py cpu20 2048 16384 32768`, GEN=64, NCMOE=20): pp
  **982 t/s at 2K, 852 t/s at 16K** (15 364 tokens in 18 s), **586 t/s for a 17K delta at 32K depth**; tg 26.1 / 30.0 /
  29.4 t/s. The host-resident experts are uploaded to the Quadro per micro-batch for batches ≥ 32 tokens (ggml's
  `offload_op`), so a 23K qwen-code system prompt still costs ~25 s, as on the all-VRAM T0 winner.
- **Why the two-device layout failed on the Q4 file (22:50–23:03, root-caused):** `IGPU_MOE=20` on `qwen35b-q4`
  died at load with `failed to allocate Vulkan0 buffer of size 998244352 … kv cache` although the Quadro held only
  11 421 MiB — and `IGPU_MOE=40` (2 039 MiB on the Quadro, 18 760 MiB on Vulkan1) died the same way while `nvidia-smi`
  showed the Quadro flat at 2 048 MiB. Not capacity. Every failing run has one earlier line in common:
  `ggml_vulkan: Failed to allocate pinned memory (ErrorOutOfDeviceMemory)` for the 515 MiB `token_embd` host buffer,
  issued right after the multi-GiB Intel (Vulkan1) allocation; ggml falls back to a plain CPU buffer and carries on, but
  **after one failed `vkAllocateMemory` every later NVIDIA allocation in the process fails too** (pinned *and*
  device-local). Proof: `--override-tensor token_embd.weight=Vulkan0` (no pinned model buffer at all) → `UP in 11 s`,
  15 396 MiB, KV 2 720 MiB and even a 520 MiB *pinned compute buffer* allocated fine seconds later. IQ2_M escaped because
  its embedding buffer (333 MiB) happened to succeed. Same driver 595.99.02 behaviour as the T0 staging crash: a failed
  or oversized pinned allocation is not survivable — **keep pinned allocations away from failure**, do not rely on
  ggml's "fall back to CPU memory" path. Noted for T2, where the host buffers get large (`--no-host` is the escape hatch
  if a pinned allocation ever fails there).
  *Update 14 Sep (results-t2.md §2.3):* the 515 MiB `token_embd` buffer failed because **the driver rejects host-visible
  allocations sized in `[n·256 MiB, +≈14 MiB)`** (515 = 512 + 3), not because of the Intel allocation before it — the same
  windows killed every qwen122b load; `patches/0002-vulkan-pad-host-alloc-windows.patch` (both builds) pads such sizes.
- **True iGPU measurement on the T1 file** (23:05–23:10, `sweep.sh qwen35b-q4 "igpu20-true=none;--override-tensor
  token_embd.weight=Vulkan0;IGPU_MOE=20"`, VRAM 15 396 MiB): **tg 16.09 / 16.20 t/s, pp 5.6 / 7.0 t/s** against
  CPU-RAM 29.9 / 31.3 and 83–90 (§2) — the same 2× / 15× as on IQ2_M. `IGPU_MOE` is **retired** for T1/T2 (kept in
  `serve.sh` for experiments only). *Caveat:* this sweep ended at 23:10:08, 33 s before the AC-power loss of §3 —
  the numbers match the AC-measured IQ2_M ratio, so they are kept, flagged.
- Harness fix (23:05): `sweep.sh` word-split multi-word `EXTRA` values (`EXTRA=$extra` → `EXTRA="$extra"`), which is
  why the first `igpu20-true` row reads `START_FAILED`.

## 2. `qwen35b-q4` — Qwen3.6-35B-A3B UD-Q4_K_XL (downloaded + sha256 OK 22:36)

### 2.1 Fit ladder (`fit.sh qwen35b-q4 14 16 18 20 22 24`, NP=1, ctx 262 144, q8_0 KV, `--fit off`, 22:38–22:39)

| `NCMOE` k (expert layers in RAM) | result | VRAM after UP |
|---|---|---|
| 14 | EXITED — `failed to allocate Vulkan0 buffer of size 998244352` (KV) | — |
| 16 | EXITED — compute buffer 943 718 416 B | — |
| 18 | **UP in 12 s but unusable**: 16 070 MiB (314 MiB headroom), first request → HTTP 500 `decode() failed: vk::Device::allocateMemory: ErrorOutOfDeviceMemory` (ggml-vulkan's lazily grown pre-allocations) | 16 070 MiB |
| **20** | **UP in 11 s, first request OK** — the fit | **15 144 MiB** (15 184 after warm-up, 1 200 MiB headroom) |

Lesson written into `fit.sh`'s usage: *UP is not fit* — a config with < ~1 GiB of headroom must also survive its first
decode. Buffer accounting at k=20 (`-lv 5`): Vulkan0 model **11 420.80 MiB** + Vulkan_Host model **9 893.31 MiB**
(20 layers × 0.49 GiB — twice IQ2_M's 0.225) + KV **2 720 MiB** (10 full-attention layers of 40) + Vulkan0 compute
**900 MiB** + host compute 528 MiB. k=19 untested (would leave ~0.7 GiB — below the lesson's line).

### 2.2 Speed sweep (`sweep-qwen35b-q4.csv`, 22:41–22:52, on AC — see §3; codebench 2 prompts, greedy, 2 048 tokens)

| label | config | pp t/s (48 / 52-token prompts) | tg t/s (prompt 0 / 1) | agg tg | note |
|---|---|---|---|---|---|
| `cpu18` | `NCMOE=18` | — | — | — | START_FAILED (k=18 is not a fit) |
| **`cpu20`** | **`NCMOE=20`, `SPEC=none`** | **83.4 / 89.8** | **29.88 / 31.34** | **30.69** | **the T1 config of this file** |
| `cpu20-ngram` | `NCMOE=20`, `SPEC=ngram-mod` | 84.9 / 97.7 | 28.36 / 27.98 | 28.16 | −4…−8 % → `SPEC=none` stays |
| ~~`igpu20`~~ | `IGPU_MOE=20` *without* `NCMOE=0` | 82.5 / 95.6 | 28.78 / 28.64 | 28.72 | **false test**: the model's default `--n-cpu-moe 20` (a `=CPU` override listed first) shadowed the `=Vulkan1` override — identical VRAM 15 144 MiB gave it away; `serve.sh` now sets `NCMOE=0` whenever `IGPU_MOE>0` unless given explicitly |
| `igpu20-true` | `IGPU_MOE=20`, `NCMOE=0`, embeddings on Vulkan0 | 5.6 / 7.0 | 16.09 / 16.20 | 16.16 | §1, the real iGPU number |
| `cpu20-ac2` (13 Sep 12:27, chain 2) | `NCMOE=20` re-run on a healthy GPU, settle step, `ac=1` | 61.0 / 96.8 | 32.40 / 30.89 | **31.56** | reproduces the 12 Sep 30.69 (+3 %) — the 12 Sep sweep stands as valid |
| `cpu20-nohost` (12:32) | `NCMOE=20`, `EXTRA=--no-host` (CPU-side tensors in plain instead of pinned host memory, unlocks the "extra" repacked CPU buffer types) | **35.8 / 74.4** | 33.57 / 31.80 | 32.55 | +3 % tg, **−20…−40 % pp** (un-pinned uploads for the offloaded experts' activations) — off |
| `cpu20-t16` (12:37) | `NCMOE=20`, `THREADS=16` | 51.0 / 89.7 | 31.87 / 29.00 | 30.22 | −4 % tg, pp down on prompt 0: SMT threads add contention on the bandwidth-bound expert reads (same as `qwen35b-q8` §5.2) → THREADS stays 8 |

**Against the T1 goal** (≥ 6 t/s output, floor 4, ideal 7–10): `qwen35b-q4` at `NCMOE=20` generates **30.7 t/s** on
short prompts — 3× above the ideal band, half of the IQ2_M all-VRAM winner (61.3), with prompt processing that still
runs on the Quadro. `models.sh`: `MODEL_NCMOE=20` confirmed for `qwen35b-q4`. Variants (13 Sep, chain 2): `--no-host`
and 16 threads both rejected; the frozen T1 knobs for this file are the plain defaults (`NCMOE=20 THREADS=8 SPEC=none`).

### 2.3 Depth bench (valid run 13 Sep 12:39–12:50, chain 2) and E2E

`GEN=64 bench.py q4cpu20 2048 16384 65536 131072` was run 23:11–23:27, i.e. entirely **on battery** (§3): pp 266 →
110 t/s, tg 6.66 → 4.83 t/s from 2K to 66K depth. Those numbers are *not* the config's — the Quadro was capped at
P2/1035 MHz and the CPU parked at 0.9–1.1 GHz — and are recorded only as the trail that led to the discovery. Re-run,
then start `e2e-all.sh qwen35b-q4`.

- 13 Sep 10:07 first re-run attempt (GPU healthy after §3.1.2) **invalid again**, this time FAIL-infra of a new kind: the
  download queue's `sha256` of a 49.8 GB shard pushed the PCH to 95–100 °C and the watchdog capped the CPU to 1.2 GHz
  (§3.3) — `q4cpu20-ac,2048: pp 113.5, tg 16.6 t/s` (healthy ≈ 982 / 30). Killed 10:10. Re-run only through the
  `wait-no-verify.sh` guard (no verification running, `thermal-policy.ratio` = 53).

**Valid run** (`GEN=64 bench.py q4cpu20-ac 2048 16384 65536 131072`, GPU healthy — pin check 60.23 t/s at 11:44, AC on,
no verification, `settle.py` waited 80 s after the load for the turbo band: cap ratio 24 → 53, PCH 90 → 75 °C):

| requested depth | new tokens evaluated (`prompt_n`; the prefix comes from the prompt cache) | pp t/s (new tokens) | tg t/s (64 tokens) | wall s | note |
|---|---|---|---|---|---|
| 2 048 | 1 953 | **831** | **32.5** | 4.3 | matches the sweep (`cpu20-ac2` 31.6) |
| 16 384 | 15 364 | 758 | 33.0 | 22.2 | flat — the 20 offloaded layers cost nothing extra at this depth |
| 65 536 | 50 180 | 412 | 26.6 | 124 | tg −18 % vs 2K |
| 131 072 | 66 564 | 195 | 22.9 | 344 | 66.5K new tokens at depth 64–131K (341 s); tg −30 % vs 2K |

(Correction 14 Sep: the second column is the number of *newly evaluated* tokens — `bench.py` sends exact-token prefixes
with `cache_prompt: true`, so each row only prefills the delta — and the deepest point really is 131K; the original
reading "the prompt is capped at 66.5K" was wrong, see the headroom block at the end of this section.) Two observations
for the T1/T2 design:

- **Prefill is *not* CPU work here.** The watchdog's one-minute samples during the whole 6-minute 66.5K prefill show
  `pkg=6.7–7.4 W, freq 4.2–4.4 GHz on one core` — the CPU was idle; llama.cpp streams the CPU-resident expert weights to
  the Quadro for batched prompt processing (the classic partial-offload behaviour, ≥ 32 tokens per ubatch) and computes
  there. This is why pp survived the offload in §1 and why `--no-host` (un-pinned host memory) cost 20–40 % pp in §2.2:
  the streaming runs out of the pinned host buffers. For T2 (all experts in RAM) this also means prefill speed will be
  set by PCIe streaming (7–8 GB of expert weights per 1024-token ubatch over PCIe 3.0 x16) plus attention — *not* by
  the 8 CPU cores — so the "≈ 65–120 t/s prefill" CPU-bound estimate is a floor, not the expectation.
- **pp at depth** (412 t/s for the 15–65K range, 195 t/s for 64–131K) while T0's all-VRAM `qwen35b` did a cold
  64 436-token prompt at 591 t/s (results-t0.md) — first read as a VRAM-pressure cliff; the 14 Sep headroom test at the end
  of this section shows it is the ordinary attention cost at depth (the candidates below are moot, kept as the trail).
  Candidates considered then: with 15 144 of 16 384 MiB VRAM taken by weights
  + KV, the Vulkan compute/scratch buffers for flash-attention at 50K+ keys fall back to host memory
  (`GGML_VK_ALLOW_SYSMEM_FALLBACK`) or shrink; or the streamed-weights path serialises with the attention at depth.
  Measurable when the GPU is free: `NCMOE=22`/`24` (more VRAM headroom) at 65536/131072 depth vs `NCMOE=20`, and the
  same points on `kat-q4`/`qwen35b-q8`. The E2E tasks record per-request pp at depth 23–130K (`per-request.txt`), which
  will show whether this bites real agentic work (T0 saw 252–406 t/s for 1–4K batches at 25–40K depth).

**Headroom attempt 14 Sep 07:01 (chain 3 step 2, `GEN=64 bench.py q4cpu22-hd 2048 65536 131072` with `NCMOE=22`) — FAIL-infra,
GPU pinned.** The first row came out `q4cpu22-hd,2048: pp 256.6, tg 11.69 t/s` (healthy k=20: 831 / 32.5). Cause: **`acpi_acad0:
Off Line` 07:02:00 → `On Line` 07:02:12** (12 s, battery 100 %), one minute after the k=22 server came up; from that moment
the Quadro sat at 1035 MHz / P2 at 99 % utilisation and 45–48 W with the *Idle* clock-event reason — the §3.1 pin. Chain 3
killed 07:04; reference pin check 07:05 `pin-0705,64: 16.32 t/s, 1035 MHz P2` = **PINNED** (13 Sep 11:29 gave 16.32 too).
As on 13 Sep only a cold power-off releases it (driver reload tried and failed then) → the k=22/24 headroom points and the
flashnext fits wait for the owner's power cycle; the CPU-side and documentation work continues. Fourth AC event of the
campaign (13 Sep 00:0x long, 06:47:55 21 s, 10:58:07 30 min, 14 Sep 07:02:00 12 s): every one of them left the GPU pinned.

**Headroom measured 14 Sep 08:07–08:26 (chain 4 step 2, GPU healthy — pin check 63.27 t/s at 07:55, no AC event during the step, cap 5300 throughout):**
`GEN=64 bench.py q4cpu2{2,4}-hd2 2048 65536 131072` with `NCMOE=22` and `24`. First a correction of the table above: the third
column is the server's `timings.prompt_n`, i.e. the tokens *newly evaluated* in that request — `bench.py` sends exact-token
prefixes with `cache_prompt: true`, so each row prefilled only the delta over the previous depth (the "131072" row really
reached 131K: 66 564 new tokens on top of the 64.5K already cached). Nothing was capped; the earlier "cliff past 50K" reading
and the "75 t/s marginal" arithmetic were wrong.

| k (expert layers on the CPU) | 2 048: pp / tg | 65 536 (new tokens 64.5K, depth 1–64K) | 131 072 (new 66.5K, depth 64–131K) |
|---|---|---|---|
| **20** (frozen; 13 Sep, 16 384 row in between) | **831 / 32.5** | 412 (50 180 new, depth 15–65K) / 26.6 | **195 / 22.9** |
| 22 (`q4cpu22-hd2`, VRAM ≈ 14.4 GiB) | 779 / 23.8 ‡ | 449 / 25.9 | 200 / 22.8 |
| 24 (`q4cpu24-hd2`, VRAM ≈ 13.8 GiB) | 721 / 24.4 ‡ | 401 / 26.1 | 193 / 16.9 ‡ |

- **VRAM headroom changes nothing at depth**: 64–131K prefill runs at 193–200 t/s for k = 20, 22 and 24 alike, and 1–64K at
  401–449. The pp decline with depth (831 → ~430 → ~195) is the attention cost of a 64–131K context (T0's all-VRAM model
  shows the same shape: 1 362 t/s at 2K, 591 t/s for a cold 0–64K prompt, 252–406 t/s for small batches at 80–130K,
  results-t0.md) plus the fixed ~35–40 % partial-offload penalty — not a memory cliff. Moving more layers to the CPU only
  costs shallow-depth pp (−6 % / −13 %). **`NCMOE=20` stays frozen.**
- ‡ The tg cells marked ‡ are **not trustworthy**: 23.8 / 24.4 t/s at 2K (and 16.9 at 131K for k=24) where every other
  measurement of this model on the same day says ~31–32 (`t1-final` codebench 31.35 at 08:02, k=20; the *pinned* k=22 row of
  07:02 gave 11.69, which with the §6.1 factor extrapolates to ≈ 32 healthy). The server's own timings show the same 2.6 s
  for 64 tokens, so it is not a measurement artefact of `bench.py` — something on the CPU side ran slower during these two
  10-minute windows (no watchdog cap, no AC event, PCH 70 °C; `powerd` is active and the 5-s telemetry cannot resolve a
  3-second generation phase). A control row (k=20 through `bench.py` on the same machine state) was queued but the GPU pin of
  08:36:59 (drop #5, §6.2) pre-empted it; the k=22/24 pp columns are unaffected and answer the headroom question on their own.

### 2.4 E2E rust/go/c/asm (chain 2, `e2e-all.sh qwen35b-q4`, started 13 Sep 12:52 after pin check 61.19 t/s)

**Grading (introduced 13 Sep, owner's ranking; `asgard/scoreboard.py` computes it from every `summary.txt`, retroactively for T0):**
`FAIL-infra` = the machine compromised the run (battery marker etc.; not charged to the model) · `FAIL-task s/T (which checks)` =
the program failed T−s of the verifier's T checks — *spec-only* when everything functional passed and only a spec rule
(signature, nodeps, vet, strict, nolibc) was missed · `PASS s/T` = all checks passed; turns / tool calls / errors, wall and the
verifier's quality lines say *how good* the run was. The verifiers keep their old output and append `score= functional= spec=`.

| model | task | grade | wall | turns / tool calls / errors | tg t/s (agg; min–max) | max depth | quality | notes |
|---|---|---|---|---|---|---|---|---|
| qwen35b-q4 | rust | FAIL-task 4/5 (spec-only: signature) | 155 s | 11 / 10 / 2 | 27.7 (22.3–31.8) | 26K | tests=4, unsafe=0, roundtrips=18ok/0bad | — |
| qwen35b-q4 | go | **PASS 5/5** | 317 s | 14 / 17 / 3 | 26.9 (21.5–31.0) | 34K | 6MB=ok, cmp=47ok/0bad | — |
| qwen35b-q4 | c | **PASS 5/5** | 54 min | 86 / 85 / 11 | 20.1 (16.7–26.1) | 110K | asserts=32, malloc/free=6/7, arith=420ok, malformed=ok, empty=ok | — |
| qwen35b-q4 | asm | FAIL-task 0/4 (functional: as+ld, nolibc, checks, make) | 240 min | — | 15.2 (12.4–27.5) | 240K | — | hit the wall-time cap |

rust: wrote `fn reverse(s: &str) -> String` where the spec says `pub fn` — 4 unit tests, 18/18 round-trips (Polish, emoji,
combining marks), no deps, `chars().rev()`; T0 `qwen35b` (IQ2_M) and gemma wrote `pub fn` under the same rule. The graded
scale exists for exactly this case: a 4/5 spec-only miss, not a broken program.

c (14:01, 54 min): the longest T1 run so far — 86 turns, 85 tool calls, 11 tool errors, depth up to **110K tokens**
(CTX 131072 held; tg fell from 26 to 16.7 t/s at the deep end, 20.1 aggregate; the 23K system prompt prefilled at 565 t/s,
later 1–6K batches at 126–205 t/s). All 5 checks (make, make test, ASan self-test, 420 arithmetic comparisons, strict flags)
passed; 32 asserts, malformed/empty input handled. The qwen122b shard-2 verification ran in the c→asm gap 14:01–14:07
(46.3 GiB, hashing 98 s at 482 MB/s, 8 safety pauses at 88 °C, PCH max 89, no cap trip) — the yield mechanism works.

asm (14:08–18:08, **FAIL-task 0/4, hit the 4 h cap** — same outcome as T0 `qwen35b` on this task): 62 turns, 25 model
requests, 204K generated tokens in 3.7 h (15.2 t/s aggregate, 12.4 at the deep end), depth up to **240K tokens** (CTX 262144
held, KV never truncated). Pattern: three *thinking-only* answers of 25–33K tokens each (27–33 min, no text, no tool call),
then `b64.s` rewritten from scratch 7 times; the last version still does not assemble (`(%r10,%r8b)` as an index register,
`or` register-type mismatch) and mixes ABIs (`SYS_WRITE = 4` FreeBSD, `SYS_READ = 0` / `SYS_EXIT = 60` Linux). No infra
event: ac_drops=0, resumes=0, no cap trips during the run. Prefill of the 82K re-sent context ran at 387 t/s; small
5–7K batches at 240K depth only 67–101 t/s (the §2.3 pp cliff).

## 3. Infra event — **AC power lost 23:10:41** (FAIL-infra; no model or run is charged with it)

`/var/log/messages`: `Sep 12 23:10:41 asgard kernel: acpi_acad0: Off Line` — the only AC event since the 05:55 boot
(and none during T0: every T0 and T1 number before 23:10 was on mains). Nothing on the box can unplug the adapter;
the cause is physical (adapter, cable, socket, or a brick's overcurrent trip — the true-iGPU sweep had just finished,
package 30 W + Quadro ~50 W + P630 7 W). Noticed only at 23:41 through performance forensics; the box gives no other
sign — it runs on, silently slower.

**Symptoms on battery** (all measured 23:11–23:41, `qwen35b-q4 NCMOE=20` unless noted):
- the frozen T0 winner (`qwen35b`, all-VRAM) generates **16.2 t/s instead of 61.3**; the Quadro sits at **P2,
  1 035 MHz SM / 6 801 MHz memory, 53 W, 93 % utilisation**, `clocks_throttle_reasons.active = 0x1 ("Idle")`, no
  power/thermal reason, power limit still 110 W — the driver's battery policy, not a fault;
- `qwen35b-q4 NCMOE=20`: **6.66 t/s** (was 30.7), pp 266 t/s at 2K; during the CPU↔GPU alternation the Quadro
  drops further to **P3, 300–420 MHz**, and the CPU cores stay at **0.9–1.1 GHz** for the whole 77-s generation
  (`dev.hwpstate_intel.*.epp = 100` — the thermal policy's efficiency bias — package 3–5 W);
- `epp=0` on all 16 logical CPUs lifted it to **10.2 t/s** (cores 2.6–5.0 GHz) — still 3× short, because the GPU
  stays capped; `--no-host` (plain CPU memory instead of pinned host memory) was **worse**: tg 9.0 / 7.1, pp 88 at
  2K. Both knobs are worth one re-measurement **on AC** (EPP could matter for the alternating T1/T2 pattern even
  there); neither is a battery fix. EPP restored to 100 at 23:42.
- Battery: design 8 334 mAh, last full 6 339 mAh (76 %), 54 % left at 23:42, draw 37 W → 62 min.

**Actions (23:42–23:45):** `stop.sh` (no E2E was running); download queue paused at 13.97 of 36.9 GB of Q8_0
(`.part` resumes; KAT was already `VERIFIED_OK` 23:18); display backlight 10 %; **`battery-guard.sh`** started as
root via `daemon` (`/var/run/battery-guard.pid`, log `~/local-ai-runs/battery-guard.log`): logs every 60 s, exits by
itself when AC returns, and at ≤ 5 % or ≤ 5 min left powers off *cleanly* (`shutdown -p now`) rather than let the EC
cut power mid-write — the one case where stopping the box is better than not. Idle draw on battery is ~29–33 W (the
Quadro alone idles at 12–22 W with the driver loaded).

**Invalidated (battery-mode) measurements:** the §2.3 depth bench, the EPP=100/EPP=0 512-token runs, the `--no-host`
runs, the all-VRAM control runs (23:39–23:41). **Kept:** everything up to 23:10:08, the `igpu20-true` sweep flagged.

**When AC is back:** (1) `battery-guard.log` shows `AC restored`; (2) re-validate the GPU on the frozen T0 config —
`./start.sh qwen35b; GEN=128 python3 bench.py ac-chk 64` must give ≈ 57–61 t/s with the Quadro at P0 ≥ 1 500 MHz;
(3) resume the queue (`daemon -f -o ~/local-ai-runs/dl-t1.log sh ~/local-ai-runs/dl-t1-queue.sh` — it skips verified
files); (4) redo §2.3 (depth bench, EPP=100 vs 0 once), then start the `qwen35b-q4` E2E. Follow-ups for the box:
the thermal-watchdog now logs `ac=0/1` per line and raises an `EVENT AC POWER LOST / restored` on transitions — patched file deployed 23:48 (`.new` + `mv`), effective at the next `service thermal_watchdog restart` (owner's call; the running copy is the old one).

### 3.1 AC back 00:01:31 — but the Quadro stays at base clock (open at 00:35, 13 Sep)

`Sep 13 00:01:31 acpi_acad0: On Line`; battery 41 % → charging at ~38–40 W (`hw.acpi.battery.state=2`); the guard
exited by itself, backlight back to 60, download queue resumed 00:07 (Q8 `.part` continues).

**Symptom.** The all-VRAM T0 control (`./start.sh qwen35b; GEN=256 bench.py … 64`) gives **15.3–16.4 t/s instead of
57–61**; `nvidia-smi` under load: **P2/P3, SM 1035 MHz** (= the Quadro RTX 5000 Mobile *base* clock, i.e. GPU Boost
off), mem 5000–6801 MHz, 45–56 W of the 110 W limit, 93 % util, clock-event reason **0x1 "Idle" only** — no SW power
cap, no HW slowdown, no thermal, no power brake, counters all 0; PCIe Gen3 x16; no NVRM errors in `dmesg`/messages.
Idle it sits at P0 1035 MHz / 7000 MHz (never P8). The CPU is *not* capped (4.4 GHz seen at 00:19). `sudo nvidia-smi
-lgc 1500,2100` is accepted and ignored (still 1035) — reset with `-rgc`; `-lmc` unsupported.

**Root-cause work (tool: `asgard/nvpowersrc.c` → `~/local-ai-runs/nvpowersrc`, a user-space RM ioctl client built from the
open-gpu-kernel-modules headers; all controls used are `RMCTRL_FLAGS_NON_PRIVILEGED`):**

| probe | result |
|---|---|
| `NV2080_CTRL_CMD_PERF_GET_POWERSTATE` | RM believes **`battery`** while `hw.acpi.acline=1` |
| `SET_POWERSTATE ac` | accepted; a *new* first-client attach (GPU wake) re-reads it → `battery` again; with a server already attached it stays `ac` |
| bench with RM = `ac` | mem clock 6801 instead of 5000 in some runs, **SM still 1035**, 16.3 t/s |
| `SET_AUX_POWER_STATE P0` (D-notifier path) | accepted (status 0), no change |
| `RATED_TDP_GET_CONTROL` ×5 clients | all `DEFAULT`; `GET_STATUS` not exported (0x56) |
| `RATED_TDP_SET_CONTROL OS/GLOBAL = FORCE_EXCEED` | accepted, no change (reverted to DEFAULT) |

Reading: the FreeBSD nvidia driver has no `_PSR` notifier (the Linux one, `nv-acpi.c`, calls
`rm_power_source_change_event` on the AC-adapter ACPI notify); it re-reads the power source only when the GPU wakes for a
first client and that read says "battery" — most likely the platform's own AC/DC signal (battery `_BST` state 2 =
charging, or the EC's DC-mode GPIO to the GPU) rather than `_PSR`. Since *every* RM-side lever is accepted but the SM
clock never moves, the base-clock pin is enforced **below the RM** — PMU/VBIOS "battery boost" limit driven by a
hardware signal from the Dell EC, or the EC's power budget while fast-charging. Nothing further can be done from
software without `nvidia-smi -r` / a driver reload / a reboot (all forbidden).

**Watching:** `~/local-ai-runs/gpu-cap-watch.sh` (user `daemon`, pidfile `~/local-ai-runs/gpu-cap-watch.pid`, log
`gpu-cap-watch.log`) polls every 10 min — AC/battery state, RM belief, a 20 s all-VRAM bench + clocks — and exits the
moment tg ≥ 50 t/s. Hypothesis under test: the pin lifts when the battery reaches full (state 2 → 0). Polls so far:
00:24 (60 %) 16.3 t/s, 00:28 (64 %) 15.3 t/s. **Every speed number since 23:10 is invalid; fits are not.**

**If it is still pinned in the morning (owner):** unplug/replug the AC once (lets the EC/driver re-evaluate); if that
does not do it, a reboot is the remaining option (owner's call). Pending anyway: `service thermal_watchdog restart`.

#### 3.1.1 Closed 01:20 — the pin is the Dell EC's AC/DC line to the GPU; the FreeBSD driver has no ACPI power path at all

- **01:07 battery full** (`hw.acpi.battery.life=100 state=0`) — still 16.3 t/s, P2/1035 MHz, RM still `battery` → the
  "lifts at full charge" hypothesis is **refuted** (polls 00:39 73 % 17.1, 00:49 82 % 16.3, 01:07 100 % 16.3 t/s).
- **Driver source** (`NVIDIA-FreeBSD-x86_64-595.99.02.tar.xz`, `src/nvidia/nvidia_acpi.c`, the open kernel glue of the
  package on asgard): `nv_acpi_get_powersource()` → `NV_ERR_NOT_SUPPORTED`; `nv_acpi_method()` (every `_DSM`, i.e. the
  NBCI/NVHG D-notifier handshake) → `NV_ERR_NOT_SUPPORTED`; `nv_acpi_methods_init()` → 0 handles; no ACPI notify
  handler; `rm_power_source_change_event` / `rm_acpi_notify` are declared in `nv.h` and **never called anywhere** in the
  FreeBSD glue. In `RmInitAdapter` (open-gpu-kernel-modules 595.99.02 `osinit.c:2383`) the RM only learns the OS power
  source *if* that call succeeds — so on FreeBSD the RM's power source is exclusively the GPU's own hardware AC/DC sense
  (the EC-driven GPIO the VBIOS declares), which is exactly what `nvpowersrc` reports and what the PMU's DC clock limit
  follows. `SET_POWERSTATE` only writes the software mirror; the hardware line wins.
- **Platform side** (`sudo acpidump -s` → `~/local-ai-runs/acpi/asgard-acpi-595.dsl`): `\_SB.AC._PSR` = `ECG2()` (the EC's
  AC bit — this is `hw.acpi.acline=1`, correct). The GPU's other channel, the D-notifier (EC event 0x8000 → EC reg 0x2E
  = 0xD1…0xD5 → `EV10` → `PEGP.EVD2` → `Notify(PEGP, level)`, acknowledged through `_DSM` `HGPS`/`PLMT`), is dead on
  FreeBSD: `EVD2` only fires once the driver has registered via `_DSM` (`VOTF`), which never happens. So the EC drives two
  independent outputs — the ACPI AC bit (fine) and the GPU's AC/DC line — and the latter has said **DC since 23:10:41**.
- **Consequence:** there is no software fix on this driver/OS combination (confirms "below the RM"). Owner: unplug/replug
  the AC (the EC re-identifies the adapter and re-drives the GPU line); if that does not release it, reboot. Under the pin
  the T1 candidates run at **qwen35b-q4 11.5 t/s (30.7 healthy)** and **qwen35b-q8 7.3–8.0 t/s** (healthy unknown), the
  all-VRAM control at 16.3 (61) — the GPU part is ~4× slower, so **no E2E is started under the pin** (the 4-h cap would
  turn into FAIL-infra noise); fits and the memory work below are unaffected. Watch loop restarted 01:19.
- **06:47–06:50 — owner replug did NOT release it.** `/var/log/messages`: `acpi_acad0: Off Line` 06:47:55, `On Line` 06:48:16
  (21 s unplugged, battery 100 %, state 0). Watch loop paused, `qwen35b` all-VRAM bench 06:50: **16.31 t/s, P2 1035 MHz**, RM
  still `battery`, reason 0x1; re-checked 07:12 with the new `vram` profile: 15.18 t/s, P3 1035 MHz. So the EC does not
  re-drive the GPU's AC/DC line on a short replug either. Remaining remedies, all owner actions (never done by the assistant):
  (a) suspend/resume — `zzz` with no model loaded, wake with the power button (`unstick.sh pre-suspend/post-resume` path,
  tested 12 Sep 07:26); (b) cold power cycle / Dell power drain: `shutdown -p now`, unplug AC, hold the power button 20–30 s,
  boot (GELI passphrase at the console). A warm reboot may not reset the EC. Until one of these clears it every T1 *speed*
  number stays invalid (memory fits, functional checks, downloads and docs continue); healthy reference ≈ 57–61 t/s on
  `GEN=256 bench.py X 64` with `qwen35b`.

#### 3.1.2 Released 10:04 (13 Sep) — only a cold power-off with a power-button hold did it; what the pin really was

- **09:49 warm reboot** (`shutdown -r`): still pinned — bench `post-reboot` 15.31 t/s, 1035 MHz P3. (`webcamd_enable=YES`
  was set on the way, it had been explicitly NO.)
- **09:58–09:59 S3 suspend/resume** (`zzz`, no model loaded, power button to wake): still pinned — `post-zzz` 16.31 t/s,
  P2 1035/6801 MHz. XFCE came back without a mouse pointer until a VT switch and back (a resume hook is a candidate fix; the
  10:15 lid open/close cycle restored it fine).
- **10:04 full power-off, AC unplugged, power button held 30 s, boot 10:05: RELEASED** — `post-poweroff` **57.97 t/s** at
  depth 64, 1830 MHz P0, 107 W (healthy 57–61). Re-checked 10:31 with the CPU capped at 1.6 GHz by §3.3 (`gpu-check-1031`):
  **63.47 t/s**, SM 1680–1935 MHz P0, 108 W, only clock-limit reason `sw-power-cap` (the normal power limiter); idle drops
  to P8 / 300 MHz afterwards.
- **Corrections.** (1) `nvpowersrc` says `battery (1)` in *both* states (checked 10:06 on the healthy GPU): on FreeBSD the
  RM's power-source field is simply never updated (§3.1.1, no ACPI path) — it is a constant, **not** a pin indicator.
  (2) **1035 MHz is the RTX 5000 Mobile base clock**, so the pin was exactly "boost disabled" — the PMU's DC clock limit.
  (3) A GPU with no client attached that is woken by an `nvidia-smi` query also reports 1035 MHz P0 for a few seconds (RM
  re-init default, 17–18 W) — that is *not* a pin; only a **loaded** GPU sitting at 1035 MHz is. `/data/scripts/temp.sh` now
  prints SM/mem clocks, max clocks and the limit reasons with that caveat.
- **What tripped it.** `/var/log/messages` `acpi_acad0`: Off Line **23:10:41 → On Line 00:01:01 (50 min)**, Off 00:01:29 →
  On 00:01:31, Off 06:47:55 → On 06:48:16 (the owner's replug). `tuxi` on the same mains stayed up (1 d 16 h) → not a mains
  outage: the adapter's output (or the barrel/ID-pin contact) dropped. A 50-minute gap under E2E load (GPU 108 W + turbo CPU
  ≈ 200+ W at the wall) matches a Dell 240 W brick's over-temperature cut-out, and the EC then latches the GPU's DC line
  until flea power is drained. Owner: check the brick's temperature/seating; if it recurs under load, swap the adapter.
- **It recurred — 4th dropout 13 Sep 10:58:07** (`acpi_acad0: Off Line`, watchdog `AC POWER LOST` 10:58:12, still off at
  11:16, battery 100 → 79 % in 18 min at ~52 W draw): one second after `sweep.sh kat-q4 cpu19-t16` came UP and the first
  codebench request hit GPU + 8 CPU threads at once, i.e. exactly at a load step — like 23:10:41 (mid-E2E). Nobody touched
  the plug (owner away, lid open). Two of four drops sit on load transients → over-current/over-temperature trip in the
  brick or a marginal barrel/ID-pin contact, not mains (`tuxi` fine again). Effects: CPU 898–998 MHz at 6 W package,
  Quadro P5 360 MHz / 23 W with no limit reason flagged (`freq_levels` reads `2400/-1` on mains too — not diagnostic) — so every
  number taken on battery is silently 3–4× low (`cpu19-t16` 7.2 t/s, `qwen35b-q8 cpu29` 4.3 t/s = both INVALID, FAIL-infra).
  Fix on the software side: `asgard/wait-ac.sh` (blocks while `hw.acpi.acline=0`, +60 s settle) now runs before every
  sweep config and every E2E task, sweep START lines carry `ac=`, and chain 2 re-checks the GPU for the 1035 MHz pin before
  it resumes. Owner side: reseat/replace the 240 W brick (check its wattage label and heat), try another outlet/cable.
- **11:27:54 mains back (owner unplugged/replugged the brick — "it was discharging, I don't know why"), battery charging at
  39 W. 11:29:49 chain-2 pin check on the all-VRAM model: tg 16.32 t/s, SM max 1035 MHz under load → PINNED again**, exactly
  as after the 23:10 drop. So the rule is confirmed: *every* AC-adapter drop with a loaded GPU ends in the 1035 MHz boost
  lock, and only the cold power-off (+ AC unplugged + 30 s power-button hold) releases it. Until the adapter/jack is fixed,
  each load-step drop costs a power cycle — chain 2 exits with code 2 on a pinned GPU instead of measuring garbage.
- **11:33 driver reload tried (owner's idea): `kldunload nvidia-modeset` (took nvidia.ko with it), 8 s, `kldload nvidia-modeset`** —
  dmesg shows the second `nvidia0: <Quadro RTX 5000>` attach, Xorg unaffected (it runs on i915 `card0`). Loaded bench right
  after: **16.49 t/s, SM 1035 MHz in P2 at 57 W, no Clocks-Event reason flagged → still pinned.** Consistent with the 09:49
  warm reboot (a full driver re-init on mains) not helping: the DC boost limit is held outside the driver (EC → GPU
  power-source signal / PMU latch), so nothing software-side clears it. Cold power-off remains the only remedy.
- **11:36–11:41 owner: `shutdown -p`, AC unplugged, 30 s power-button hold, replug, power on → 11:44:10 pin check
  60.23 t/s, SM max 1935 MHz → HEALTHY** (second time the procedure worked, first time it was needed twice in one day).
  Pool clean, `.part` download resumed from 34.2 GB, watchdog up (ratio 53). Chain 2 continued on its own.
- **Rules from here.** Pin check = `./start.sh vram; GEN=256 python3 bench.py X 64` → ≥ 55 t/s **and** SM ≥ 1600 MHz P0 under
  load (`nvidia-smi --query-gpu=clocks.sm,pstate`), done before and after every E2E model. Remedy order if pinned: cold
  power-off + AC unplugged + 30 s power-button hold (the only thing that worked); warm reboot and S3 do not. The watchdog logs
  `AC POWER LOST` on `hw.acpi.acline` changes since 01:xx, so the next drop is visible in `/var/log/thermal.log` at once.

### 3.2 Second FAIL-infra of the night, fixed: ZFS ARC starved the NVIDIA pinned host buffers (00:53–01:05)

`ALL=1 fit.sh qwen35b-q8 27 29 31 33` died at every k within 17–30 s: 24× `ggml_vulkan: Failed to allocate pinned memory
(vk::Device::allocateMemory: ErrorOutOfDeviceMemory)` (the `Vulkan_Host` buffer that llama.cpp uses for the `--n-cpu-moe`
experts — ~0.8 GiB/layer × 27–33 layers), then, 13 s later, `failed to allocate Vulkan0 buffer of size 998244352` for the
KV cache = the known first-failure poisoning of every later NVIDIA allocation in the process (§0/T0 notes).

**Cause.** `top`: `92G Wired, 30G Free, ARC 88G` (`kstat.zfs.misc.arcstats.size` 94.2 GB, `c_max` unlimited = 126.6 GiB),
`v_user_wire_count` = 4 pages. The 11 Sep switch to `primarycache=all` on `zroot/data/local-ai` (results-t0.md §consequences
1) plus 37 GB of downloads and every mmap'd model load had grown the ARC to fill RAM. The NVIDIA driver's pinned host
allocations need wired system memory *now*; they do not wait for ARC reclaim — they fail (and poison the client). Q4 k=20
and KAT k=19 (9–11 GiB pinned) squeezed into the 30 GiB; Q8 (21–26 GiB) did not. The T0 `qwen9b` "256 MiB pinned
allocation fails near 256K" incidents are very probably the same mechanism (ARC full after the model downloads) — noted
as a likely FAIL-infra reclassification; T0 stays frozen, the winner was decided on quality.

**Fix (all runtime, reversible, done as `sudo`):**
1. `sysctl vfs.zfs.arc.max=17179869184` (16 GiB) + the same line in `/etc/sysctl.conf` (commented). ARC target dropped to
   13 GiB within seconds, but the evicted buffers stayed parked in UMA zones (still 92 GiB wired) …
2. … so `sysctl debug.uma_reclaim=2` (drain) → **wired 92 → 15 GiB, free 30 → 106 GiB** in 5 s (`=3` adds per-CPU caches;
   asgard has **no swap**, so memory-pressure tricks were not an option).
3. `zfs set primarycache=metadata zroot/data/local-ai` — back to the readme recipe (the 11 Sep `all` was for 10 s T0
   restarts of 11 GiB files; T1/T2 need that RAM for weights, and a ≤ 16 GiB ARC cannot hold a 34 GiB model anyway). Model
   restarts now come from the page cache (pages survive `munmap`) or NVMe (4-way mirror, ~12 s for 35 GiB).

Re-run of the same ladder: 0 pinned-memory warnings, every k loads (§5). Rule for T2: keep the ARC cap (lower it to 8 GiB
if a T2 model needs the room) and check `top` "Wired" before any fit — pinned failures are an infra symptom, never a model
one.
*Update 14 Sep:* a second, independent cause of the same warning is the driver's size windows `[n·256 MiB, +≈14 MiB)`
(results-t2.md §2.3; fixed by `patches/0002-vulkan-pad-host-alloc-windows.patch` in both builds) — with the ARC capped and
the padding in place, a `Failed to allocate pinned memory` warning would be a new phenomenon and must be root-caused again.

**Prior art on tuxi (looked up 13 Sep 07:25 at the owner's request; `/data/ai/freebsd-local-agent-poc.md` Incidents 3–7,
scripts in `/data/ai/`, same copies on asgard):** the 6 Sep 2026 ARC saga on the 61.75 GiB tuxi was the *double copy* problem —
ZFS caches every `read()`/`mmap` of the GGUF, so weights sat in llama's buffer **and** in the ARC → OOM-kill / `DeviceLost` /
host freeze. Two root scripts were prepared: **option 1** `arc-fix-option1-dio.sh` (`vfs.zfs.dio_enabled=1` + `--load-mode dio`,
O_DIRECT) and **option 2** `arc-fix-option2-dataset.sh` (dedicated dataset, `primarycache=metadata`). **Option 2 won**: dio hung
the host twice with the gate off (Incidents 3/4) and, with the gate on, *silently fell back to buffered I/O* because llama's GGUF
reads are not page-aligned (`direct=standard`; Incident 7) — "dio is a dead end with this build". The final form is
`local-ai-dataset.sh` (`zroot/data/local-ai`, `primarycache=metadata compression=off`, the recipe asgard inherited) plus
`--load-mode none`. Option 3 (ARC cap `vfs.zfs.arc.max`, `primarycache=none` pool-wide) stayed a fallback; `set-arc-limit.sh
[GiB]` (default 2, persisted) and `arc-flush.sh [GiB]` (temporary lower-then-restore) were used while testing, and the owner
later set tuxi back to `arc.max=0` once everything was settled. asgard today: `dio_enabled=1` is inherited via
`/etc/sysctl.conf` and inert (nothing opens O_DIRECT); the dataset is back on `metadata`; **the difference here is the second
consumer** — NVIDIA pinned host buffers fail *instantly* when the ARC has grown into the RAM they need, and an unlimited ARC
grows on any big read (ports, `git fetch`, the 240 MB llama.cpp fetch this morning), not only on model loads — so on asgard the
cap stays (16 GiB now, 8 GiB for the 87 GiB Flash-Next fits) for the whole T2 phase, and `arc-flush.sh`'s trick becomes
`debug.uma_reclaim=2` when Wired does not follow the ARC down. Revisit `arc.max=0` only after T2 is frozen.

### 3.3 Third FAIL-infra class, 13 Sep 10:05–10:45: the PCH heats under *any* sustained NVMe read stream

- **Timeline.** Queue restart after the power-off → `sha256 -q` of Flash-Next shard 2 (49.8 GB) from 10:05:22, lid closed
  10:05:30; depth bench started 10:07. PCH 95 °C at 10:07:35 → watchdog `HOT … -> cap 2000/1800/1600/1400/1200 MHz` by
  10:08:04 (that is what made §2.3's row invalid). Bench and server stopped 10:10 — the PCH **kept rising: 103 → 107 °C** at
  10:12:36 with the sha256 as the only load, every core at 36–37 °C, NVMe 55–58 °C, CPU at 1.1 GHz. `kill -STOP` on the
  sha256 at 10:13:23 → **93 °C after 10 s, 82 °C after 60 s**, 71 °C at 10:16. Lid opened 10:15:57.
- **Rate is not the lever.** A 40 MB/s rate-limited hasher (`zpool iostat`: exactly 40.0 MB/s) took the PCH **79 → 97 °C in
  4 min** (10:24–10:28, lid open), same slope as the 98 MB/s `sha256`. Any sustained read keeps the four PCH PCIe links + DMI
  out of L1: the PCH die jumps ~8–10 °C within seconds, then creeps ~6 °C/min; it falls just as fast when the reads stop.
  Downloads alone are harmless (curl writes ~10 MB/s in txg bursts: PCH 64–67 °C, cap 5300, all morning 07:50–09:40).
- **What the hardware/kernel offers, checked:** `pchtherm` T0/T1/T2 hardware link throttle = **108/111/114 °C**, CTT 120
  (BIOS-locked, read-only) — exists, far too high; `pmtemp` 77 °C is only the power-management threshold (temp.sh used to
  call it "self-throttles at 77", corrected). NVMe HCTM 70/77 °C acts on the *drive's* temperature (drives sat at 45–58 °C).
  `rctl readbps/writebps throttle` needs `kern.racct.enable=1` (loader.conf + reboot) and accounts buffer-cache IO only —
  ZFS bypasses it. `gnop -r/-w` delay layers cannot be inserted under the live root pool. ZFS vdev tunables only reduce
  concurrency. → the duty cycle has to be done by the reader itself.
- **Fixes (all in `download.sh`'s path, nothing else):** `asgard/verify-slow.py` — duty-cycled sha256, **40 s burst / 15 s
  gap** by default (owner's choice 10:35, first tried on the next file = `qwen122b`), PCH safety pause at 100 °C → resume
  85 °C, `--burst/--cool/--pch-hi/--pch-lo/--mbps` args or `VERIFY_*` env; its first closed-loop version (pause ≥ 84, resume
  ≤ 74) did Flash-Next shard 3: 20 s bursts at ~135 MB/s (CPU capped), 15–35 s gaps, PCH 73–85 °C, cores 35 °C.
  `download.sh` writes a marker `models/.verified/NAME` (`bytes sha256 date`) after a pass and never re-hashes a marked file
  (`REVERIFY=1` forces) — the old re-hash-on-every-run plus queue restarts is where the *two* simultaneous sha256 at 101 °C
  came from; `dl-t2-queue.sh` runs under `lockf -t 0`. `wait-no-verify.sh` is called by `sweep.sh` (per config) and
  `e2e-all.sh` (per task): no timing run starts while a verification runs. A watchdog-side SIGSTOP/SIGCONT duty cycle was
  deployed 10:17 and **reverted 10:21 on the owner's instruction** (byte-identical restore verified); the owner instead
  raised the conf to `WD_PCH_HI=100 / WD_PCH_LO=90` (10:36, CRIT 115 unchanged).
- **Rule.** Before any speed number: `pgrep -f verify-slow` empty, `cat /var/run/thermal-policy.ratio` = 53, PCH < 85 °C.
  Verification windows are logged in `~/local-ai-runs/dl-t2.log` (`verify-slow HH:MM:SS start/done`) — an E2E task that
  overlaps one gets it noted in the report (mid-task overlaps are unavoidable, the download queue must not wait for E2E).

### 3.4 iGPU clock: knobs and behaviour under load (13 Sep)

The Intel UHD P630 (i915, `card0`) exposes its Linux sysfs frequency files as sysctls through linuxkpi:

| sysctl (`sys.class.drm.card0.`) | value | meaning |
|---|---|---|
| `gt_RPn_freq_mhz` / `gt_RP1_freq_mhz` / `gt_RP0_freq_mhz` | 350 / 350 / 1250 | hardware floor / efficient / max |
| `gt_min_freq_mhz`, `gt_max_freq_mhz`, `gt_boost_freq_mhz` | 350, 1250, 1250 | **RW (root)** software limits |
| `gt_cur_freq_mhz` / `gt_act_freq_mhz` / `gt.gt0.punit_req_freq_mhz` | dynamic | RPS request / actual hw clock / PUnit request |
| `gt.gt0.rps_up_threshold_pct` / `rps_down_threshold_pct` | 95 / 85 | RPS busy thresholds (gen9 host-managed RPS) |

- Control works: `sudo sysctl sys.class.drm.card0.gt_min_freq_mhz=1250` → `gt_cur_freq_mhz` 1250 immediately (10:48:1x);
  `gt_act_freq_mhz` follows only while the iGPU is awake (parked/RC6 it reads 350). Reverted to 350 afterwards; RPS then
  stepped `cur` 1250 → 733 by itself on the next Xorg wake, i.e. the dynamic scaling is alive on FreeBSD too.
- Automatic climb under an `IGPU_MOE` load: measured by `~/local-ai-runs/igpu-freq-sampler.sh` during the `igpu19`
  (kat-q4) and `igpu29` (qwen35b-q8) sweep configs — see the table below. Verdict: no pinning needed, the RPS climbs on its own.
- If RPS ever sits below 1250 under expert load (bursty kernels can stay under the 95 % up-threshold), the fix is a
  one-liner per run: `gt_min_freq_mhz=1250` before `start.sh`, `=350` after — a candidate `IGPU_MIN_MHZ` hook for
  sweep.sh/start.sh, only worth adding if the sampler shows it is needed.

| config | server `--device` | act MHz min / typical / max while generating | note |
|---|---|---|---|
| `igpu19` kat-q4, 10:54:40–10:55:10 (generating) | `Vulkan0,Vulkan1` | 350 (1 RC6 dip) / **1150** / 1250 — RPS request 1217–1250 the whole time | climbs within 5 s of the first expert kernels (act 1150 already during the model upload at 10:54:25); 1150 rather than 1250 most of the time = package-power sharing with the CPU threads, not RPS |
| `igpu29` qwen35b-q8, 12:08:58–12:18:11 (whole config, 110 samples at 5 s) | `Vulkan0,Vulkan1` | 350 (16 samples = load phase + RC6 dips between prompts) / **1150** (79 samples) / 1250 (7 samples; 1083–1233 in 8) | same picture over a 9-minute run: the P630 sits at 1150–1250 MHz whenever expert kernels are queued — the iGPU is *not* clock-starved, it is simply slow (igpu29 tg 6.36 vs cpu29 21.45 t/s, §5.2) |

## 4. `kat-q4` — KAT-Coder-V2.5-Dev Q4_K_L (Qwen3.6-35B-A3B fine-tune, `VERIFIED_OK` 23:18)

### 4.1 Fit ladder (`ALL=1 fit.sh kat-q4 18 20 22`, then k=19 by hand, 00:26–00:31; memory only → valid despite the clock pin)

| `--n-cpu-moe` | VRAM at UP | note |
|---|---|---|
| 18 | 15 654 MiB | too tight (Q4_K_XL k=18 came UP at 16 070 and 500'd on the first decode) |
| **19** | **15 223 → 15 267 MiB after the first request** | **chosen** — ~1.1 GiB headroom, same margin as the Q4_K_XL k=20 that survived a full sweep |
| 20 | 14 725 MiB | safe fallback |
| 22 | 13 863 MiB | — |

Q4_K_L is ~0.42 GiB/layer lighter than UD-Q4_K_XL (14 725 vs 15 144 at k=20), hence one layer more in VRAM.
`models.sh kat-q4 MODEL_NCMOE=19`. Speed sweep: §4.2 (13 Sep). E2E: chain after the sweeps.

**Functional check 01:22 (pinned GPU, one chat request, `enable_thinking: true`):** llama-server picks the Qwen3 template
("chat template supports preserving reasoning"), thinking lands in `reasoning_content` (118 chars), the answer in `content`
(a correct SWAR `popcount64` + complexity note), `finish_reason=stop`, 406 tokens in 29.7 s ≈ 13.7 t/s under the pin (k=19).
Same kwargs/sampling as `qwen35b`, so `sweep.sh kat-q4 "none=none"` and `e2e-all.sh kat-q4` need no template work.

### 4.2 Speed sweep (`sweep.sh kat-q4`, 13 Sep 10:47–10:59 + THREADS A/B 14 Sep 06:50–07:01, GPU healthy — first T1 numbers without the clock pin)

`codebench.py LABEL 2` (two short coding prompts, thinking on, own EOS), GAP 150 s, PCH 69–86 °C, cap 5300 throughout,
no verification overlap (`wait-no-verify.sh` idle). CSV: `~/local-ai-runs/sweep-kat-q4.csv`.

| config | placement of the 19 expert layers | tg t/s (aggregate) | pp t/s (48 / 52-token prompts) | wall s (2 prompts) | note |
|---|---|---|---|---|---|
| `cpu19` (`NCMOE=19`, THREADS 8) | CPU RAM | **25.22** | 79 / 99 | 26 | baseline = `models.sh` default |
| `cpu19-ngram` (`SPEC=ngram-mod`) | CPU RAM | **26.48** | 66 / 92 | 25 | +5 % tg, −15 % pp — not worth it on 200–400-token answers |
| `igpu19` (`IGPU_MOE=19 NCMOE=0`) | iGPU (Vulkan1, shared RAM) | 16.78 | **6.3 / 7.1** | 53 | tg −33 %, pp 12× slower; iGPU clock was 1150–1250 MHz while generating (§3.4) |
| `cpu19-t16` (`THREADS=16`) | CPU RAM | ~~7.21~~ **INVALID** | ~~41 / 33~~ | — | **the AC adapter dropped at 10:58:07, one second after this config came UP** (`acpi_acad0: Off Line`; battery = CPU 1 GHz / 6 W, GPU P5 360 MHz) → FAIL-infra, re-run pending on mains (chain 2) |
| `cpu19-t16b` (`THREADS=16`, re-run 11:47:04–11:47:24, chain 2, GPU healthy after the cold power-off) | CPU RAM | **34.02** (33.80 / 33.97) | 80 / 93 | 20 | **+35 % tg vs 8 threads** — and that with the CPU *capped* 2400→3200 MHz the whole 20 s (START pch=92 → the watchdog had dropped the turbo band after the 21 GB load; the settle step in sweep.sh was added after this run). Answers were as short as in `cpu19` (209 + 424 tokens), so the KV-depth is comparable. Needs one uncapped confirmation run (`cpu19-t16c`) — scheduled after the E2E cycle |
| `cpu19b` (THREADS 8, **A/B 14 Sep 06:50**, chain 3, back-to-back, settle-guarded, cap 5300, AC 1) | CPU RAM | **26.15** | 78 / 95 | 24 | A/B run 1 |
| `cpu19-t16c` (THREADS 16, A/B 06:53) | CPU RAM | **27.87** | — | 23 | A/B run 2 |
| `cpu19c` (THREADS 8, A/B 06:57) | CPU RAM | **26.35** | — | 24 | A/B run 3 |
| `cpu19-t16d` (THREADS 16, A/B 07:00) | CPU RAM | **27.60** | — | 23 | A/B run 4 |

Conclusion for `kat-q4` (three valid configs, all on mains — the 10:58:07 AC drop came *after* `igpu19` ended 10:55:14):
**VRAM + CPU RAM (`NCMOE=19`, 8 threads, no spec)** — 25 t/s is 4× the T1 goal (≥ 6) and even above the "ideal" 15–25 band
of T0. The iGPU/RAM split is out for the T1 models (same verdict as `qwen35b-q4` on 12 Sep: `igpu20` 16.2 vs `cpu20` 30.7):
the UHD P630 is simply too weak for the expert matmuls, and it is *catastrophic* for prompt processing (6–7 t/s — a
100 K-token coding context would take hours). ngram-mod stays off (spec gains vanish on real reasoning output). **THREADS=16 wins for kat-q4, but only by +5.5 %** — the 13 Sep +35 % (34.02) was the outlier the previous version of this
paragraph suspected: the settle-guarded back-to-back A/B of 14 Sep 06:50–07:01 (chain 3; four loads, GAP 150 s, cap 5300,
PCH 68–79 °C, AC on, GPU healthy) gives 8 threads **26.15 / 26.35** and 16 threads **27.87 / 27.60** t/s (27.7 vs 26.25,
spread within each arm 0.2–0.3). The 34.02 run (11:47, right after the cold power-off, CPU capped 2400→3200 MHz) is kept
in the table for the record but not used. Note the sign differs from the Qwen files — `qwen35b-q8` (§5.2: 20.14 vs 21.45)
and `qwen35b-q4` (§2.2: 30.22 vs 31.56) *lose* 4–6 % with 16 threads — so THREADS stays a per-model knob
(`MODEL_THREADS` in models.sh): **kat-q4 = 16** (confirmed; also what its E2E ran with), Qwen files = default 8.
E2E rust/go/c/asm with these settings: chain step after the sweeps.

### 4.3 E2E rust/go/c/asm (chain 2, `e2e-all.sh kat-q4`, 13 Sep 18:16–20:05, THREADS 16, pin check 64.00 t/s before)

| model | task | grade | wall | turns / tool calls / errors | tg t/s (agg; min–max) | max depth | quality | notes |
|---|---|---|---|---|---|---|---|---|
| kat-q4 | rust | **PASS 5/5** | 136 s | 7 / 11 / 2 | 29.2 (27.7–31.1) | 26K | tests=4, unsafe=0, roundtrips=18ok/0bad | — |
| kat-q4 | go | FAIL-task 4/5 (functional: comparisons) | 10 min | 14 / 36 / 2 | 24.8 (20.6–28.3) | 45K | cmp=46ok/1bad | — |
| kat-q4 | c | **PASS 5/5** | 50 min | 38 / 108 / 24 | 20.3 (16.8–28.7) | 125K | asserts=2, malloc/free=5/4, arith=420ok, malformed=ok, empty=ok | — |
| kat-q4 | asm | FAIL-task 0/4 (functional: no project) | 40 min | — | 18.3 (18.3–24.9) | 114K | — | — |

- **rust PASS 5/5 in 136 s** (fastest of all models so far): `pub fn reverse`, 4 tests, 18/18 round-trips, 7 turns.
- **go 4/5**: `bufio.Scanner` over stdin → `token too long` on the 6 MB single-line input (rc=1, no output) — the same
  check that failed gemma and north; the Qwen family (qwen35b, qwen9b, qwen35b-q4) read the whole input and pass it.
  46/47 comparisons otherwise byte-exact, vet/nodeps ok, 14 turns, 10 min.
- **c PASS 5/5 after a verifier fix** (ops.md 19:45): the first grading said 2/5 because `verify-c.sh` built its ASan binary
  before the project's `make clean`, and kat's Makefile `clean` removes `bignum-asan`; the `make test` check also looked
  only at the last 3 output lines while kat prints `selftest ok` first. Re-verified with the fixed script: make, make test,
  strict, ASan self-test, 420/420 arithmetic lines, malformed/empty input all ok. 38 turns, 108 tool calls, **24 tool
  errors** (the noisiest run), 50 min, depth 125K, tg 20.3 aggregate (16.8 at the deep end).
- **asm FAIL-task 0/4 (no project) in 40 min**: two requests, both *thinking only* — the first hit the 32 768-token output cap
  (33 min at 18.3 t/s, no text, no tool call), qwen-code re-sent the context (101K prompt at 264 t/s), the second answer was
  empty and the agent returned `success` with an empty result. No file written. Same task class as q4's 4 h loop and T0's
  cap: x86-64 asm defeats every 35B-class model tried so far; the *manner* differs (kat gives up after one 32K thought, q4
  loops for 4 h).
- No infra event in any of the four runs (ac_drops 0, resumes 0, downtime 0).

**kat-q4 vs qwen35b-q4 (same tasks, same day):** rust 5/5 vs 4/5 (q4's missing `pub`), go 4/5 vs 5/5, c 5/5 vs 5/5
(kat: 38 turns/50 min, q4: 86 turns/54 min), asm 0/4 vs 0/4 (40 min vs 4 h). Speed at depth: kat 16.8–29 t/s, q4 12.4–32.
The THREADS A/B (chain 3) decides whether kat's 16-thread setting is real; the E2E ran with it.

## 5. `qwen35b-q8` — Qwen3.6-35B-A3B Q8_0 (36 903 140 320 B, `VERIFIED_OK` 00:52 after a curl short-read at 32.4 GB and a resume)

### 5.1 Fit ladder (`ALL=1 fit.sh qwen35b-q8 27 29 31 33`, 01:00–01:04, after the §3.2 fix; memory only → valid despite the clock pin)

| `--n-cpu-moe` | VRAM at UP | note |
|---|---|---|
| 27 | — | `ggml_gallocr_reserve_n_impl: failed to allocate Vulkan0 buffer of size 1212153872` (compute buffer) |
| **29** | **15 011 → 15 052 (after 64 tok) → 15 064 MiB (after a 4 096-token request)** | **chosen** — 1.3 GiB headroom; tg **7.31 / 8.03 t/s at depth 64 / 4 096 under the pin**, pp 223 at 4 096 |
| 31 | 13 382 MiB | safe fallback |
| 33 | 11 752 MiB | — |

≈ 815 MiB per Q8 expert layer (vs ≈ 460 for UD-Q4_K_XL, ≈ 420 for KAT Q4_K_L); k=28 would land at ~15.8 GiB = the
"UP-but-OOM at first decode" zone. `models.sh qwen35b-q8 MODEL_NCMOE=29` (was the plan estimate — confirmed). Speed
sweep and E2E: after the GPU boosts again. Even pinned, 7.3–8.0 t/s already sits inside the T1 goal band (≥ 6, ideal 7–10).

### 5.2 Speed sweep — first attempt 13 Sep 11:03 INVALID (on battery since 10:58:07, §3.1.2): `cpu29` prompt 0 gave tg 4.26 /
pp 23 t/s with the CPU at 1 GHz and the Quadro in P5; killed at 11:14. Re-run on mains: chain 2 (`~/local-ai-runs/t1-chain2.sh`).

Re-run (chain 2, `sweep.sh qwen35b-q8`, 13 Sep 11:50–12:24, GPU healthy 60.23 t/s pin check at 11:44, AC on for every
START/END line, no verification overlap). `codebench.py LABEL 2`, GAP 150 s. CSV: `~/local-ai-runs/sweep-qwen35b-q8.csv`.
Q8 answers are long (1 651–2 048 tokens per prompt, the 2 048 cap hit on prompt 1 every time) so these tg values are
measured over ~3 400–3 800 generated tokens per config — the most robust T1 numbers so far.

| config | placement of the 29 expert layers | tg t/s (aggregate) | pp t/s (48 / 52-token prompts) | wall s (2 prompts) | START pch / cap | note |
|---|---|---|---|---|---|---|
| `cpu29` (`NCMOE=29`, THREADS 8) | CPU RAM | **21.45** (21.49 / 21.40) | 43 / 48 | 178 | 88 / 5300 | baseline = `models.sh` default; 3.6× the T1 goal, inside the T0 "ideal" band |
| `cpu29-ngram` (`SPEC=ngram-mod`) | CPU RAM | 20.65 | 46 / 54 | 181 | 91 / 5300 | −4 % tg — ngram-mod is a loss on Q8 reasoning output too; off |
| `igpu29` (`IGPU_MOE=29 NCMOE=0`) | iGPU (Vulkan1, shared RAM) | 6.36 | **4.0 / 5.1** | 552 | 93 / **2400** | tg −70 %, pp 10× slower. The START cap was 2400 (PCH 93 after the 37 GB load; turbo band back at ~12:11, so ≥ 7 of the 9 minutes ran at 5300) and the iGPU held 1150–1250 MHz (§3.4) — tainted but decisive: 29 Q8 expert layers on the P630 is a non-starter |
| `cpu29-t16` (`THREADS=16`) | CPU RAM | 20.14 (20.00 / 20.24) | 37 / 54 | 190 | 87 / 5300 | −6 % tg, −15 % pp on prompt 0: 16 threads do **not** help Q8 (the 815 MiB/layer experts are memory-bandwidth bound; SMT only adds contention). Opposite of kat-q4 (§4.2) → THREADS stays 8 for `qwen35b-q8` |

Conclusion for `qwen35b-q8`: **VRAM + CPU RAM (`NCMOE=29`, 8 threads, no spec) at 21.4 t/s**, pp 43–48 t/s. The Q8
model is 3.2× larger on the expert side than UD-Q4 and still lands at 70 % of `qwen35b-q4`'s `cpu20` (30.7–31.6 t/s, §2.2)
rather than at half: both are limited by DDR4 bandwidth for the expert reads per token (Q8 reads ~2× the bytes of Q4
per expert layer, but 29 vs 20 offloaded layers and the 11 GPU-resident layers + attention identical for both blur the
ratio). The iGPU/RAM split is dead for T1 (third model, same verdict: 16.2 / 16.8 / 6.4 t/s vs 31 / 25 / 21 on CPU RAM).
E2E rust/go/c/asm: chain 2, after `qwen35b-q4` and `kat-q4`.

### 5.3 E2E rust/go/c/asm (chain 2, `e2e-all.sh qwen35b-q8`, 13 Sep 20:08–22:25; asm rerun 14 Sep 06:17 killed again; THREADS 8, pin check 63.01 t/s)

| model | task | grade | wall | turns / tool calls / errors | tg t/s (agg; min–max) | max depth | quality | notes |
|---|---|---|---|---|---|---|---|---|
| qwen35b-q8 | rust | FAIL-task 3/5 (functional: roundtrips, signature) | 302 s | 10 / 10 / 1 | 20.7 (19.4–21.1) | 28K | tests=4, unsafe=0, roundtrips=15ok/3bad | — |
| qwen35b-q8 | go | FAIL-task 4/5 (functional: comparisons) | 573 s | 23 / 22 / 4 | 20.2 (19.2–21.0) | 36K | cmp=46ok/1bad | — |
| qwen35b-q8 | c | **PASS 5/5** | 118 min | 53 / 52 / 4 | 16.7 (13.5–20.7) | 127K | asserts=26, malloc/free=13/7, arith=420ok, malformed=ok, empty=ok | — |
| qwen35b-q8 | asm | FAIL-infra (machine froze) | 280 s | — | — | — | — | — |
| qwen35b-q8 *(superseded attempt 20260914-061725)* | asm | FAIL-infra (machine froze) | 259 s | — | — | — | — | — |

- **rust FAIL-task 3/5 in 302 s**: `fn reverse` without `pub` (same spec miss as q4) *and* a functional bug — the program
  reversed only the first stdin line (`ab\ncd` → `ba` instead of `dc\nba`), 15/18 round-trips; 4 unit tests pass.
- **go FAIL-task 4/5 in 573 s**: `bufio.Scanner` over stdin, 64 KB token limit → the 6 MB single-line input yields *rc=0 and
  empty output* (kat/gemma/north at least exited 1); 46/47 comparisons ok, vet/nodeps ok, 23 turns.
- **c PASS 5/5 in 118 min** (slowest c run of T1: q4 54 min, kat 50 min): 53 turns, 52 tool calls, 4 tool errors, depth 127K,
  tg 16.7 aggregate (13.5 at the deep end — Q8 experts move ~2× the bytes of Q4 per token), 26 asserts, 420/420 arithmetic
  lines, malformed/empty input ok. It finished at 22:24, five minutes before the machine died (ops.md 22:29:45).
- **asm FAIL-infra ×2 (machine froze)**: both attempts died silently *inside the first 82K-token prefill* — 13 Sep 22:29:45
  (~250 s in, progress ≈ 0.88) and the rerun 14 Sep 06:22:05 (~270 s in, progress ≈ 0.95). Nothing was generated either time, so
  the model is not graded; the archived attempt is `asm-task-qwen35b-q8.prev-20260914-061725`. Only q8 needs > 250 s for this
  prompt (pp 292 t/s; q4 did it in 212 s at 387 t/s and survived; the sweeps' 127K-token deltas at ~100–108 W also survived),
  and the telemetry before death #1 shows the GPU at **140.7 / 127.7 / 122.5 W against its 110 W limit** with EC-asserted
  HW-slowdown flags (0x4C) — a power-path event, not heat (GPU 67–73 °C, PCH 63–80). Not rerun unattended; see ops.md 14 Sep
  for the (failed) mitigation attempts (`-pl` unsupported, `-lgc`/`-pm` lost the device handle).

**q8 vs q4 (same model, Q8_0 vs UD-Q4_K_XL, k=29 vs 20):** rust 3/5 vs 4/5, go 4/5 vs 5/5, c 5/5 vs 5/5 (118 vs 54 min),
asm FAIL-infra ×2 (untestable: the box died twice in its prefill) vs 0/4. At ~2× the wall time and 0.65× the tokens/s, Q8 bought nothing in outcomes on these four tasks —
one sample each, but consistent with the sweep: q8 21.4 t/s vs q4 31.6.

## 6. T1 verdict — **`qwen35b-q4` wins on coding quality** (2026-09-14 07:20; `fast|t1` profile frozen in models.sh)

Owner's ranking rule (14 Sep 07:15): pick the T1 winner by **coding output quality**, not speed; keep every model on disk;
speed is measured again on the best candidates with a small task once the GPU pin is gone (owner restart). Quality is
unaffected by the pin — greedy decoding produces the same tokens at any clock, only the wall time changes.

E2E scoreboard (`scoreboard.py`, verifier checks per task rust 5 / go 5 / c 5 / asm 4; "spec-only" = every functional
check passed and only a spec check was missed; T0 `qwen35b` = the IQ2_M all-VRAM winner of results-t0.md as reference):

| model | rust | go | c | asm | raw score | functional failures | wall (rust / go / c / asm) |
|---|---|---|---|---|---|---|---|
| **`qwen35b-q4`** UD-Q4_K_XL, `NCMOE=20`, 8 thr | 4/5 **spec-only** (`fn reverse(s: &str) -> String` signature not used; 18/18 round-trips) | **PASS 5/5** (6 MB input ok, 47/47 comparisons) | **PASS 5/5** (32 asserts, 420/420 arithmetic lines, malformed + empty input ok) | 0/4 — **hit the 240-min cap while still working** (240K tokens at 15 t/s) | 14/19 | **0** | 155 s / 317 s / 54 min / 240 min (cap) |
| `kat-q4` Q4_K_L, `NCMOE=19`, 16 thr | **PASS 5/5** | 4/5 functional (`6 MB input rc=1, got=b''`; 46/47 comparisons) | **PASS 5/5** (2 asserts) | 0/4 — **runaway thinking**: one response with a 100 080-char thinking block, cut by the 32 768-token output cap, zero tool calls, no project (40 min) | 14/19 | 1 (+ the runaway) | 136 s / 10 min / 50 min / 40 min |
| `qwen35b-q8` Q8_0, `NCMOE=29`, 8 thr | 3/5 functional (15/18 round-trips + signature) | 4/5 functional (46/47) | **PASS 5/5** (26 asserts) | FAIL-infra ×2 (machine froze during the 82K-token prefill, §5.3) | 12/15 | 2 | 302 s / 573 s / 118 min / — |
| T0 `qwen35b` UD-IQ2_M, all VRAM | PASS 5/5 | PASS 5/5 | 4/5 functional (malformed lines) | 2/4 (cap; encode 1/700) | 16/19 | 1 | 110 s / 256 s / 43 min / 240 min (cap) |

**Why `qwen35b-q4`:**

1. It is the only model in the whole campaign (T0 included) with **zero functional failures on rust/go/c** — its single
   missed check is the exact-signature spec in rust; the program itself round-trips 18/18. Its C solution is also the
   most thoroughly tested one (32 asserts vs 2 for KAT, 26 for q8).
2. `kat-q4` ties on the raw score but has a real correctness bug (the 6 MB input case of the go task returns nothing) and
   showed a failure mode that matters for agentic use: on the asm task it *thought* for 32K tokens without acting. Same
   architecture and bit-width, so nothing is gained on resources either (it needs THREADS=16 for its +5.5 %, §4.2).
3. `qwen35b-q8` — 1.65× the weight bytes and 15 GiB more RAM — is functionally *worse* than q4 on rust (3 bad round-trips)
   and go, equal on c, and 30 % slower (§5.2). Its asm result is unknowable without a rerun (both attempts froze the box
   at maximum GPU power, §5.3); even 2/4 would only tie q4's raw total while staying behind on functional failures. A
   pinned-regime rerun would be power-safe (GPU ≤ 57 W) but slow; it cannot realistically change this verdict.
4. Caveat kept on record: the T1 asm zeros are **not pure quality signals** — q4 was cut by the wall-time cap (at 15 t/s
   it generated 240K tokens; T0's IQ2_M at 30 t/s got to 2/4 in the same 240 min), KAT by its own runaway. If asm-class
   tasks matter, rerun q4's asm after the restart with a higher cap (`E2E_CAP=28800 e2e-test.sh qwen35b-q4 asm`).

**Frozen (`models.sh model_env fast|t1` → `qwen35b-q4`):** `NP=1 CTX=262144 SPEC=none NCMOE=20 IGPU_MOE=0 THREADS=8
THREADS_BATCH=16` (`MODEL_CACHE_RAM=8192`, thinking on) — the §2.2 sweep winner: 31.6 t/s tg and 831 t/s pp at 2K depth,
22.9 t/s / 195 t/s at 66.5K depth on a healthy GPU (§2.3). Nothing is deleted: `kat-q4` and `qwen35b-q8` stay on disk
(owner's instruction; `kat-q4` remains the natural second candidate for the small-task speed follow-up).

*Update 14 Sep 11:48 (owner):* with the verdict final and `kat-q4`'s small-task speed follow-up done (§6.3, 28.73 t/s), the
owner asked to remove the T1 non-winners: `Kwaipilot_KAT-Coder-V2.5-Dev-Q4_K_L.gguf` (20.3 GiB) and `Qwen3.6-35B-A3B-Q8_0.gguf`
(34.4 GiB) were deleted (305 → 250 GB used on `zroot/data/local-ai`), their `models.sh` entries dropped (settings stay in git
history and in §4–§5 above; the `fast|t1` header line of models.sh now records the frozen knobs instead of "not frozen yet"),
and the `kat-q4|qwen35b-q8` mentions in the `qwen.sh` / `llamactl.sh` / `serve.sh` headers were replaced by the T2 candidates.
The disk holds the T0 winner, the T1 winner and the three T2 files only.

**What happened next:** the owner cold-rebooted asgard 07:44 (releases the GPU pin, §3.1.2); the small-task output-t/s
follow-up on the best candidates is in **§6.3** (`t0-final` 60.55, `t1-final` 31.35, `kat-final` 28.73 t/s — all back at
their healthy values); T2 (`flashnext`, `qwen122b`, `qwen122b-iq4`) follows the same quality-first rule (results-t2.md).

### 6.1 GPU-pin calibration — how much slower the pinned regime is, and how to extrapolate (14 Sep 07:12–07:37, `t1-chain3b.sh` step 1)

The pin (§3.1) is reproducible to the second decimal — the all-VRAM reference gives 16.30–16.32 t/s on 13 and 14 Sep — so a
pinned measurement is a consistent regime, just a slow one. Under load it reads **SM 1035 MHz, P2, memory 6801 MHz (7000
max), clock-event reason "Idle"**: an SM/P-state lock, not a memory-clock cut, yet the all-VRAM slowdown (3.75×) is twice
the SM-clock ratio (1935/1035 = 1.87×) — P2 evidently costs more than the reported clocks say. Same prompts, greedy, same
token counts in both arms (the `TOTAL` rows list them), GAP 150 s, settle-guarded, AC on, `~/local-ai-runs/sweep-*.csv`
and `pin-calib.log`:

| config (workload) | healthy tg t/s (date) | pinned tg t/s (14 Sep) | **healthy / pinned** |
|---|---|---|---|
| `qwen35b` UD-IQ2_M all in VRAM (pin check: 64-token prompt, 256 generated) | 60.23 / 61.19 / 62.68 (13–14 Sep) | 16.30 | **3.75×** |
| `qwen35b-q4` `cpu20` (20 expert layers in RAM, 8 thr; 3 692 tokens) | 31.56 (`cpu20-ac2`, 13 Sep) | 10.98 (`cpu20-pin`) | **2.87×** |
| `qwen35b-q8` `cpu29` (29 layers in RAM, 8 thr; 3 767 tokens) | 21.45 (`cpu29`, 13 Sep) | 7.61 (`cpu29-pin`) | **2.82×** |
| `kat-q4` `cpu19` THREADS=16 (19 layers in RAM; 633 tokens) | 27.7 (A/B mean, 14 Sep 06:53–07:00) | 13.35 (`cpu19-t16-pin`) | 2.08× |
| `qwen35b` all VRAM, `bench.py` depth 2048 / 16384 (**pp**, tg) | **pp 1362 / 1166**, tg 61.5 / 55.7 (`vram-healthy`, 14 Sep 07:52 after the cold reboot) | pp 294 / 272, tg 15.95 / 13.57 (`vram-pin`) | **pp 4.6× / 4.3×**, tg 3.9× / 4.1× |

Reading: the pin only slows the GPU-resident part of a token (attention, dense layers, the VRAM-resident experts); the
RAM-resident experts run on the CPU at full speed. Splitting the per-token time with the all-VRAM 3.75× as the GPU
factor (`1/P = 3.75·g + c`, `1/H = g + c`) gives a GPU share of ≈ 68 % for `cpu20` and ≈ 66 % for `cpu29` — consistent
with each other. KAT's 2.08× does not fit that picture (it would mean a 39 % GPU share for the same architecture at
the same bit-width); its arms are short answers (633 tokens, 2 × ~316) where fixed per-request costs weigh more, so its
factor is the least reliable of the three — treat it as a lower bound.

**Rule of thumb for extrapolating a pinned number to a healthy GPU:** all-VRAM configs × **3.75**; T1-class configs
(about half the expert layers in RAM) × **2.8–2.9**; T2-class configs (all experts in RAM, only attention + dense on
the GPU) will be *less* than that — probably 1.3–1.8×, to be calibrated with one pinned/healthy pair when the pin is
gone. Prompt processing suffers *more* than generation under the pin: **×4.3–4.6 for all-VRAM prefill** (compute-bound, follows the
SM lock harder than the bandwidth-bound tg), ×3.2 for the T1-class `q4cpu22-hd,2048: pp 257` vs 831 healthy at k=20. None of this touches the quality ranking
in §6, which is what the T1 choice rests on.

### 6.2 What causes the GPU pins, and how the campaign now works around them (14 Sep 07:50, after the 4th event)

**Mechanism (evidence-based, not vendor-confirmed):**

1. *Trigger — an AC-adapter dropout.* Four `acpi_acad0: Off Line` events in the campaign; **every one of them left the Quadro
   locked at 1035 MHz / P2 with the "Idle" clock-event reason** (16.3 t/s on the all-VRAM reference instead of 60–63).
2. *Where the lock lives — the Dell EC, not the driver or the GPU.* Replugging the adapter, `nvidia-smi`, a driver reload
   (`kldunload/kldload nvidia-modeset`, 13 Sep 11:33), suspend (`zzz`) and a **warm reboot** (which resets the GPU) all left it
   pinned; only a **cold power-off with the adapter unplugged and a 30 s power-button hold** — the procedure that resets the
   embedded controller — released it (13 Sep 10:04, 11:43; 14 Sep 07:44). On AC loss the EC puts the dGPU into its battery
   power budget; on FreeBSD nothing renegotiates it when the adapter returns (on Windows the NVIDIA platform-power
   handshake does that), so the EC keeps the cap until it is reset.
3. *What makes the adapter drop — a load step, not heat and not average power.* In the 5-s telemetry each dropout sits exactly
   on a GPU jump from idle to full power: 12 Sep 23:10:41 (`gpu=124.6 W` in the sample of the drop, GPU idle 10 s before),
   13 Sep 10:58:07 (one second after a sweep config came UP = the warm-up request), 14 Sep 07:02:01 (the depth bench's first
   prefill after a model load). CPU package power at those moments was 13–30 W (one core at 4.4 GHz tokenising; RAPL
   PL1/PL2 35/45 W is set but "ignored by this PCU"). The same EC also brakes the GPU through its external THERM pin during
   long prefills (`0x40`/`0x08` HW-slowdown bits at GPU 67–75 °C — the `0x80` power-brake bit never appears) and clamps
   the CPU to 900 MHz whenever the GPU works — a tight platform power budget. The two freezes (§5.3) sit in the same
   regime: 1-s GPU power averages of 122–141 W against the 110 W limit, i.e. transients well beyond the nominal TGP.
   Everything fits an adapter/jack that cannot take the transient: a 180 W (or unrecognised) adapter, a degraded 240 W one,
   or a worn barrel contact whose voltage sags under a 10 A step and makes the EC declare "Off Line". **Owner check
   requested:** the adapter label (Dell 240 W = 19.5 V ⎓ 12.3 A; 180 W = 9.23 A), the BIOS "AC adapter type", and whether
   the plug/jack is warm or loose after a run.

**Avoidance measures in place:**

- `start.sh` **soft-start** (14 Sep 07:52): after `/health` every server gets a 1 → 64 → 512 → 2048-token ramp (4 generated
  tokens each, 1 s apart, ~4–15 s) before any real request, so the first prefill never lands on an idle GPU as one step.
  `SOFTSTART=0` disables it. First test on `qwen35b`: 4/4 requests in 4 s.
- Every chain step is bracketed by an **AC-drop detector** (`acpi_acad0: Off Line` count) and a pin check: a drop marks the
  step's numbers suspect, a pinned GPU stops the chain — no more mixed-regime rows.
- Pinned numbers are still usable: the pin is reproducible and §6.1 gives the factors (×3.75–3.9 tg / ×4.5 pp all-VRAM,
  ×2.8–2.9 tg T1-class); quality results (E2E grades) are regime-independent.
- Not done, owner's call: lowering the watchdog's `MAX_RATIO` (53 → 35–40) would trim the CPU's part of the transients
  (~10–20 W) and heat; the CPU was not the dominant term in any dropout, so it is a minor lever compared with the adapter.
  No software lever exists for the GPU side (`nvidia-smi -pl/-lgc/-pm` are unsupported/destructive on this driver, §3.1).

**Amendment 14 Sep 08:37–08:55 — the 5th event, and the soft-start turned out to be a no-op.**

- **Drop #5:** `acpi_acad0: Off Line` **08:36:59** → `On Line` 08:37:09 (10 s), seven seconds after the flashnext `cpuall`
  server came UP in chain 4 step 3b, i.e. on its very first prefill (telemetry 08:36:56: GPU 1395 MHz, 70 W, `0x04`; CPU
  package 13–25 W). The GPU has been pinned since — the usual signature, chain 4's end pin check 08:59:38: **16.24 t/s, 1035 MHz / P2 /
  mem 6801** (idle it now parks in P3 / mem 5000) — so the flashnext speed row of that step is FAIL-infra (results-t2.md
  §2.2) and chain 4 stopped at its pin check as designed (`exit 2`). Fifth cold power-off pending (owner).
- **The soft-start never did anything.** Its four ramp requests carried no API key, the server answered `401 unauthorized:
  Invalid API Key` (visible in `serve.out`), and the loop counted the failed curls as "4/4 in 4 s" — so the "first test on
  qwen35b" above and the finals of §6.3 ran *without* a ramp (which is also why the finals showed "no cost"). Fixed 08:50:
  `start.sh` now reads `key.secret`, uses `curl -sf` (only 2xx counts) and ramps 1 → 16 → 64 → 128 → 256 → 512 → 1024 →
  2048 tokens 2 s apart, printing `soft-start: N/8 ok`. Whether a ramp can help at all is doubtful: any prefill ≥ 32 tokens
  already runs the GPU at full utilisation, so the smallest realistic step is the whole step. Kept because it is free.
- **Sharper pattern:** of the five `Off Line` events one was the owner's replug (13 Sep 06:47:55); **all four spontaneous
  drops sit on a *partial-offload prefill*** — 12 Sep 23:10:41 q4 k=20 depth bench, 13 Sep 10:58:07 q8 k=29 warm-up, 14 Sep
  07:02:00 q4 k=22 first prefill, 14 Sep 08:36:59 flashnext `NCMOE=all` first prefill. The all-VRAM T0 model at 100–124 W GPU
  power ran many hours of finals/sweeps/E2E without a single drop, at *higher* GPU power than drop #5 (70 W). The
  partial-offload prefill is the moment when the GPU, PCIe (expert weights streamed from host RAM at ~10 GB/s) and the DDR4
  side all step up together — the platform-wide current step, not the GPU alone, is what the adapter/jack fails on. This
  narrows the owner check above: a 240 W adapter (or a fresh jack) is the cheapest next experiment; on the software side
  nothing ramps a prefill gently, so the campaign plans for pins instead (chains carry on pinned for quality, `-pin`-labelled
  speed rows, see results-t2.md §2.2).

**Amendment 14 Sep 11:53–12:20 — drop #6 on a fresh boot, and two software levers finally worth trying.**

- **Drop #6:** `acpi_acad0: Off Line` **11:53:16** → `On Line` 11:53:20 (4 s), three minutes after the owner's cold power-on,
  exactly at "UP" of the first load (`qwen122b NCMOE=all`, the patch-0002 memory-logger check) — i.e. at llama-server's
  **built-in warm-up**, which for a MoE model decodes with *all* experts active (`llama_set_warmup`): ~70 GiB of expert
  weights streamed over PCIe in one go on an idle, freshly unpinned GPU — the largest step the platform can produce, and it
  happens *before* start.sh's soft-start can ramp anything. The GPU was pinned again (chain 1's pin check 11:57: 16.23 t/s,
  1035 MHz / P2 / mem 6801). Sixth spontaneous drop, sixth first-partial-offload step; the pinned regime again produced
  hours of rows without a drop. Whether cold power-off #6 had released the pin is unknowable — the drop came first.
- **Lever 1 — `--no-warmup`** (serve.sh, 12:10): skip the all-experts warm-up. Nothing is lost: the pinned host buffers are
  filled at load (no lazy paging), the first request pays a few Vulkan pipeline compilations instead — absorbed by the ramp.
  Verified: the 12:15 load went threadpool-init → "model loaded" with no warm-up line.
- **Lever 2 — a gap-free ramp immediately before the first real request** (`ramp.py`, 12:10): 1 → 4 → 16 → 64 → 256 → 1024
  → 4096 prompt tokens (4 generated each, prompt cache off) back-to-back, so the GPU boost/power controller is already
  engaged and the platform current climbs in ≤ 4× steps instead of one cliff. Called by start.sh (replaces the 2-s-apart
  loop — whose ramp was followed by minutes of settle-wait idling, so the GPU was cold again at the real first prefill), by
  bench.py / codebench.py right after `settle()`, and by e2e-test.sh (`RAMP_MAX=16384`) before qwen-code's ~23K first
  prompt. `NO_RAMP=1` skips it. Functional test, pinned (12:15): `qwen122b k=47 MTP` UP 54 s, ramp 7/7 in 52 s, bench row
  fine, no drop. Whether a staircase helps depends on what the adapter/EC trips on — di/dt (then it should) or the absolute
  level (then only a 240 W adapter / jack fix helps); **cold power-off #7 (12:2x) is the experiment.**
- Still open, owner's call: capping the CPU turbo during T2 work (watchdog `MAX_RATIO` 53 → 35–40, or a `dev.cpu.0.freq`
  limit) would trim ~10–20 W of the transient; and the adapter label / BIOS "adapter type" / jack check from the list above.

**Amendment 14 Sep 12:16–12:30 — drop #7 four seconds into the ramp: the adapter trips on the level, not the slope.**

- Cold power-off #7 (adapter unplugged, 30 s button hold) **did release the pin**: chain 1's pin check 12:18:33 on the all-VRAM
  T0 model — **61.21 t/s, SM 1905 MHz, P0, HEALTHY**, including a 1 → 4096-token ramp at 1755 MHz / 100 W without a drop.
- The first partial-offload server (`qwen122b NCMOE=47 SPEC=draft-mtp`, `--no-warmup`) came UP 12:21:58; `ramp.py` started
  12:21:59; **`acpi_acad0: Off Line` 12:22:03** → On Line 12:22:11 (8 s) — four seconds in, i.e. at a 64- or 256-token step
  (the 1/4/16-token steps had passed). GPU pinned again (P8 idle → 1035 MHz cap under load). Seventh spontaneous drop, seventh
  first-partial-offload prefill; no drop ever in the pinned regime or on the all-VRAM model.
- **Reading:** a ≤ 256-token prefill already streams (nearly) every expert of every layer over PCIe at full rate while the GPU
  sits at boost — the platform current reaches its full level within the first step, whatever the batch. The adapter (or the
  jack) trips on that *level*; a staircase cannot lower it, and the 4–10 s "Off Line" is the signature of an adapter's
  over-current hiccup. The all-VRAM model at 100–125 W GPU power never crosses the threshold; the partial-offload path adds
  the PCIe root complex, four DIMMs at full bandwidth and the GPU's DMA engines — evidently just enough.
- **Consequence for the campaign:** with this adapter/jack **T2 (partial-offload) models will always run pinned** — the first
  prefill pins the GPU within seconds of every healthy boot. The pinned numbers are therefore T2's *real operating regime*,
  not FAIL-infra; the chains now force `-pin` labels and run every E2E phase pinned (quality is regime-independent; wall
  times are pinned-regime and say so). `--no-warmup` and `ramp.py` stay (free, and they remove the two largest steps), but
  they are not a fix. Cold power-offs are no longer requested for T2 work.
- **The fix is hardware (owner):** the adapter label (Dell 240 W = 19.5 V ⎓ 12.3 A; 180 W = 9.23 A; 130 W = 6.7 A), the BIOS
  "AC adapter type / wattage" line, a known-good 240 W adapter, and the barrel jack (warm / loose after a run). A software-side
  half-measure that remains untested is capping the CPU turbo during T2 work (watchdog `MAX_RATIO` 53 → 35–40) — it trims
  the transient by ~10–20 W, which may or may not be the margin.

### 6.3 Final small-task output t/s at the frozen settings — post-reboot, healthy GPU, soft-start on (14 Sep 07:55–08:07, `t1-chain4.sh` step 1)

Owner's follow-up from §6: measure the best candidates once more with a small real task after the cold reboot. Same
codebench pair (2 coding prompts, greedy, 2 048 tokens) as every sweep, so the rows compare 1:1 with §2.2 / §4.2 and
results-t0.md; pin check before the step `pincheck-chain4-start` 63.27 t/s (SM 1920, mem 7000) = HEALTHY, AC-drop counter
unchanged across the step (no dropout), telemetry running.

| label | model / profile | tokens | wall s | **tg t/s** | previous healthy rows (same prompts) | delta |
|---|---|---|---|---|---|---|
| `t0-final` | `qwen35b` UD-IQ2_M, all VRAM (`vram|t0`) | 3 957 | 65.3 | **60.55** | `none` 58.67 (12 Sep), pin checks 61–64 (bench.py, 64-token prompt) | +3 % |
| `t1-final` | `qwen35b-q4` UD-Q4_K_XL, `NCMOE=20`, 8 thr (`fast|t1`) | 3 692 | 117.8 | **31.35** | `cpu20` 30.69, `cpu20-ac2` 31.56, `cpu20-t16` 30.22 (12–13 Sep) | ±1 % |
| `kat-final` | `kat-q4` Q4_K_L, `NCMOE=19`, 16 thr | 633 | 22.0 | **28.73** | `cpu19-t16c/d` 27.87 / 27.60 (14 Sep 06:50, §4.2) | +3–4 % |

Read-out:

- The cold reboot **fully restored** the box: every frozen profile is back at (slightly above) its best healthy number; the
  small +1–4 % is the cooler, freshly booted machine (PCH 67–78 °C, no ARC pressure yet), not a real change.
- The **soft-start** (§6.2) costs nothing measurable on output t/s — it runs once per server start, before the prompts
  — and this is the first full step since the 4th pin without an AC dropout (n = 1, not proof).
- Winner economics for T1 on the small task: `qwen35b-q4` 31.4 t/s vs `kat-q4` 28.7 t/s (KAT's tokens are ~6× fewer
  because it answers tersely, so its wall time per prompt is much lower — but the quality verdict in §6 stands); the
  all-VRAM T0 model is 1.9× faster than T1 on the same prompts (§6 table: T0 16/19 with one functional bug vs T1 14/19
  with none — the T1 winner buys correctness, not speed).
- Pin factors from §6.1 re-checked against these rows: `t1-final` 31.35 / pinned `cpu20-pin` 10.98 = **×2.86** (§6.1 said
  ×2.87); `t0-final` 60.55 / 16.30 = **×3.71** (§6.1 ×3.75); `kat-final` 28.73 / 13.35 = ×2.15 (§6.1 ×2.08, KAT's short
  answers make it a lower bound). The calibration holds.
