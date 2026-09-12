# asgard T0 results — the `fast` profile (VRAM + iGPU/RAM overflow), started 2026-09-12 21:52

Companion to `plan.md` (§4 shortlist, §10 profiles and speed goals) and `report-t1.md` / `results-t1.md` (the T-1 phase this
continues). Same box, same regime, same harness: Dell Precision 7750, Quadro RTX 5000 16 GiB = Vulkan0, Intel UHD P630 =
Vulkan1 (Mesa ANV, 95.7 GiB UMA heap), 128 GiB DDR4, FreeBSD 15.1, llama.cpp POC fork v0.4.0 `5266f24` **`build-vulkan-2`**
(chunked staging transfers, `patches/0001-…`), "turbo band" thermal policy, BIOS Cool, EPP 100. Hard requirements as in T-1:
native 262 144 context per slot, thinking on, q8_0 K/V, flash attention, no YaRN, model-card sampling.

**T0 definition (owner, 12 Sep 11:14–11:24, plan §10)**: `fast` = VRAM first, the overflow to the **iGPU (Vulkan1) or CPU
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
| `qwen35b-q4` | Qwen3.6-35B-A3B **UD-Q4_K_XL** (unsloth, non-MTP) @ `a483e9e` | 20.8 | the T-1 winner at a real 4-bit: same behaviour, quantisation risk gone; plan estimate 20 of 40 expert layers off VRAM |
| `kat-q4` | **KAT-Coder-V2.5-Dev Q4_K_L** (bartowski, imatrix) @ `d8f684f` — Kwaipilot's agentic-coding RL fine-tune of Qwen3.6-35B-A3B, thinking kept, no MTP head | 20.3 | the coding specialist of the class; head-to-head with `qwen35b-q4` at equal size |
| `qwen35b-q8` | Qwen3.6-35B-A3B **Q8_0** (unsloth, non-MTP) @ `a483e9e` | 34.4 | the quality reference; ~29 expert layers off VRAM — is Q8 still inside the T0 goal? If not it is T1 material |

Not queued (yet): the MTP-repo files (the T-1 sweep showed n-gram speculation costs 17 % on this MoE, and with experts in
RAM every verified draft token pays the expert loads again — to be tested only if a T0 winner has speed to spare);
UD-Q5/Q6 (between Q4 and Q8 — only if Q8 misses the goal and Q4 has large headroom); Qwen3.6/3.8-27B dense (the FFN of a
dense model in RAM would run ≈ 3–4 t/s — below the T0 floor); everything ≥ 122B (T1).

## 1. iGPU vs CPU RAM — the placement question, answered first (22:00, `qwen35b` UD-IQ2_M, 20 of 40 expert layers moved)

Measured before any T0 file arrived, with the T-1 winner's file, `sweep.sh qwen35b "cpu20=none;;NCMOE=20"
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
  ≈ 0.85 ms per offloaded layer here. Consequences for T0/T1: the price of offloading scales with the **number of
  layers** whose experts leave VRAM, much less with their bytes → fill VRAM to the last expert layer (the fit ladder's
  minimum k), expect Q8_0 layers to cost about the same per layer as IQ2_M ones, and leave `--threads 8`.
- **Prompt processing is unaffected by the offload** (22:17, `bench.py cpu20 2048 16384 32768`, GEN=64, NCMOE=20): pp
  **982 t/s at 2K, 852 t/s at 16K** (15 364 tokens in 18 s), **586 t/s for a 17K delta at 32K depth**; tg 26.1 / 30.0 /
  29.4 t/s. The host-resident experts are uploaded to the Quadro per micro-batch for batches ≥ 32 tokens (ggml's
  `offload_op`), so a 23K qwen-code system prompt still costs ~25 s, as on the all-VRAM T-1 winner.
- **Why the two-device layout failed on the Q4 file (22:50–23:03, root-caused):** `IGPU_MOE=20` on `qwen35b-q4`
  died at load with `failed to allocate Vulkan0 buffer of size 998244352 … kv cache` although the Quadro held only
  11 421 MiB — and `IGPU_MOE=40` (2 039 MiB on the Quadro, 18 760 MiB on Vulkan1) died the same way while `nvidia-smi`
  showed the Quadro flat at 2 048 MiB. Not capacity. Every failing run has one earlier line in common:
  `ggml_vulkan: Failed to allocate pinned memory (ErrorOutOfDeviceMemory)` for the 515 MiB `token_embd` host buffer,
  issued right after the multi-GiB Intel (Vulkan1) allocation; ggml falls back to a plain CPU buffer and carries on, but
  **after one failed `vkAllocateMemory` every later NVIDIA allocation in the process fails too** (pinned *and*
  device-local). Proof: `--override-tensor token_embd.weight=Vulkan0` (no pinned model buffer at all) → `UP in 11 s`,
  15 396 MiB, KV 2 720 MiB and even a 520 MiB *pinned compute buffer* allocated fine seconds later. IQ2_M escaped because
  its embedding buffer (333 MiB) happened to succeed. Same driver 595.99.02 behaviour as the T-1 staging crash: a failed
  or oversized pinned allocation is not survivable — **keep pinned allocations away from failure**, do not rely on
  ggml's "fall back to CPU memory" path. Noted for T1, where the host buffers get large (`--no-host` is the escape hatch
  if a pinned allocation ever fails there).
- **True iGPU measurement on the T0 file** (23:05–23:10, `sweep.sh qwen35b-q4 "igpu20-true=none;--override-tensor
  token_embd.weight=Vulkan0;IGPU_MOE=20"`, VRAM 15 396 MiB): **tg 16.09 / 16.20 t/s, pp 5.6 / 7.0 t/s** against
  CPU-RAM 29.9 / 31.3 and 83–90 (§2) — the same 2× / 15× as on IQ2_M. `IGPU_MOE` is **retired** for T0/T1 (kept in
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
| **`cpu20`** | **`NCMOE=20`, `SPEC=none`** | **83.4 / 89.8** | **29.88 / 31.34** | **30.69** | **the T0 config of this file** |
| `cpu20-ngram` | `NCMOE=20`, `SPEC=ngram-mod` | 84.9 / 97.7 | 28.36 / 27.98 | 28.16 | −4…−8 % → `SPEC=none` stays |
| ~~`igpu20`~~ | `IGPU_MOE=20` *without* `NCMOE=0` | 82.5 / 95.6 | 28.78 / 28.64 | 28.72 | **false test**: the model's default `--n-cpu-moe 20` (a `=CPU` override listed first) shadowed the `=Vulkan1` override — identical VRAM 15 144 MiB gave it away; `serve.sh` now sets `NCMOE=0` whenever `IGPU_MOE>0` unless given explicitly |
| `igpu20-true` | `IGPU_MOE=20`, `NCMOE=0`, embeddings on Vulkan0 | 5.6 / 7.0 | 16.09 / 16.20 | 16.16 | §1, the real iGPU number |

**Against the T0 goal** (≥ 6 t/s output, floor 4, ideal 7–10): `qwen35b-q4` at `NCMOE=20` generates **30.7 t/s** on
short prompts — 3× above the ideal band, half of the IQ2_M all-VRAM winner (61.3), with prompt processing that still
runs on the Quadro. `models.sh`: `MODEL_NCMOE=20` confirmed for `qwen35b-q4`.

### 2.3 Depth bench and E2E — **pending (must be re-run on AC)**

`GEN=64 bench.py q4cpu20 2048 16384 65536 131072` was run 23:11–23:27, i.e. entirely **on battery** (§3): pp 266 →
110 t/s, tg 6.66 → 4.83 t/s from 2K to 66K depth. Those numbers are *not* the config's — the Quadro was capped at
P2/1035 MHz and the CPU parked at 0.9–1.1 GHz — and are recorded only as the trail that led to the discovery. Re-run,
then start `e2e-all.sh qwen35b-q4`.

## 3. Infra event — **AC power lost 23:10:41** (FAIL-infra; no model or run is charged with it)

`/var/log/messages`: `Sep 12 23:10:41 asgard kernel: acpi_acad0: Off Line` — the only AC event since the 05:55 boot
(and none during T-1: every T-1 and T0 number before 23:10 was on mains). Nothing on the box can unplug the adapter;
the cause is physical (adapter, cable, socket, or a brick's overcurrent trip — the true-iGPU sweep had just finished,
package 30 W + Quadro ~50 W + P630 7 W). Noticed only at 23:41 through performance forensics; the box gives no other
sign — it runs on, silently slower.

**Symptoms on battery** (all measured 23:11–23:41, `qwen35b-q4 NCMOE=20` unless noted):
- the frozen T-1 winner (`qwen35b`, all-VRAM) generates **16.2 t/s instead of 61.3**; the Quadro sits at **P2,
  1 035 MHz SM / 6 801 MHz memory, 53 W, 93 % utilisation**, `clocks_throttle_reasons.active = 0x1 ("Idle")`, no
  power/thermal reason, power limit still 110 W — the driver's battery policy, not a fault;
- `qwen35b-q4 NCMOE=20`: **6.66 t/s** (was 30.7), pp 266 t/s at 2K; during the CPU↔GPU alternation the Quadro
  drops further to **P3, 300–420 MHz**, and the CPU cores stay at **0.9–1.1 GHz** for the whole 77-s generation
  (`dev.hwpstate_intel.*.epp = 100` — the thermal policy's efficiency bias — package 3–5 W);
- `epp=0` on all 16 logical CPUs lifted it to **10.2 t/s** (cores 2.6–5.0 GHz) — still 3× short, because the GPU
  stays capped; `--no-host` (plain CPU memory instead of pinned host memory) was **worse**: tg 9.0 / 7.1, pp 88 at
  2K. Both knobs are worth one re-measurement **on AC** (EPP could matter for the alternating T0/T1 pattern even
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

**When AC is back:** (1) `battery-guard.log` shows `AC restored`; (2) re-validate the GPU on the frozen T-1 config —
`./start.sh qwen35b; GEN=128 python3 bench.py ac-chk 64` must give ≈ 57–61 t/s with the Quadro at P0 ≥ 1 500 MHz;
(3) resume the queue (`daemon -f -o ~/local-ai-runs/dl-t0.log sh ~/local-ai-runs/dl-t0-queue.sh` — it skips verified
files); (4) redo §2.3 (depth bench, EPP=100 vs 0 once), then start the `qwen35b-q4` E2E. Follow-ups for the box:
the thermal-watchdog now logs `ac=0/1` per line and raises an `EVENT AC POWER LOST / restored` on transitions — patched file deployed 23:48 (`.new` + `mv`), effective at the next `service thermal_watchdog restart` (owner's call; the running copy is the old one).
