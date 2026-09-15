# asgard T2 results — the `best` profile (VRAM + iGPU/RAM, as much model as fits), started 2026-09-13 06:55

Companion of `plan.md` §4/§7/§10 (candidates, grid, goals) and of `results-t0.md`/`report-t0.md` (T0 `fastest-vram`,
frozen: `qwen35b`) and `results-t1.md` (T1 `fast`, in progress — its speed work is parked until the owner clears the GPU
base-clock pin, results-t1.md §3.1.1). Times are CEST. Verdicts are `PASS` / `FAIL-task` (model) / `FAIL-infra`
(llama, thermal, power, network — re-run, never counted against the model).

**T2 definition (owner, 12 Sep 11:14 + 13 Sep 06:49):** the best-quality model that still runs usably — as much as fits across
VRAM + iGPU + CPU RAM, *whichever split is fastest*: for every candidate test **both** placements, VRAM + iGPU (`IGPU_MOE=N`,
Vulkan1) and VRAM + CPU RAM (`NCMOE=N|all`), plus the usual switches (SPEC none / ngram-mod / draft-mtp on MTP files, NP,
threads 8 vs 16, `--cache-ram`, `--no-host`, EPP 100 vs 0, batch sizes; never `--no-kv-offload`, never `-b 512` on Vulkan),
then pick the fastest mode per model, then the E2E coding tasks. Speed goal (output t/s, session aggregate): **≥ 1.8 t/s**,
absolute floor **1 t/s** (below = unusable), ideal **> 3 t/s**. T3 (an even bigger model) only if the owner still wants it at
the end.

> **Live state:** `asgard/STATUS.md` (restart sheet, updated at every transition) — this file is the evidence log.

## 0. Candidates and downloads (queue started 06:55, one file at a time, ~8–10 MB/s on wlan0, all resumable)

Files come from HF at a pinned revision, sharded (`-0000N-of-0000M.gguf`); llama-server opens shard 1 and finds the rest next
to it, so `models.sh` carries shard 1 as `MODEL_FILE/BYTES/SHA256` and the others as `MODEL_EXTRA='name:bytes:sha256 …'`
(`MODEL_DIR` = repo sub-folder); `download.sh` fetches and verifies every shard. Queue: `~/local-ai-runs/dl-t2-queue.sh`
(`daemon -f -o ~/local-ai-runs/dl-t2.log`), sequential, 6 retries per model, `MODEL_COMPLETE`/`QUEUE_DONE` markers.

| # | `models.sh` | model | file (repo @ revision) | size | notes |
|---|---|---|---|---|---|
| 1 | `flashnext` | **Qwen3.8-Flash-Next** (`qwen4exp`, 125B-A6B: 48 layers, 512 experts × 10 used + shared, GDN hybrid with full attention every 4th layer, QSA indexer top-k 2048, PLE n-gram table, MTP) | `unsloth/Qwen3.8-Flash-Next-GGUF` @ `38bb39ee` `UD-IQ4_XS/…-0000{1,2,3}-of-00003.gguf` | 10.9 MB + 49.8 GB + 43.8 GB = **93.7 GB (87.3 GiB)** | needs llama.cpp master ≥ b10889 → §1; MTP head only in the unsloth fork / PR #28243 (not on master) → SPEC none / ngram-mod only; ctx 262 144 native; chat template: `enable_thinking` (default true) + `reasoning_effort` xhigh (default) / medium / low |
| 2 | `qwen122b` | Qwen3.5-122B-A10B (MTP head in the file) | `unsloth/Qwen3.5-122B-A10B-MTP-GGUF` @ `907becb3` `UD-Q4_K_XL/…-0000{1,2,3}-of-00003.gguf` | 10.9 MB + 49.7 GB + 29.0 GB = **78.6 GB (73.3 GiB)** | runs on both builds; `draft-mtp,ngram-mod` to be swept |
| 3 | `qwen122b-iq4` | Qwen3.5-122B-A10B, smaller quant | same repo, `UD-IQ4_XS/…-0000{1,2,3}-of-00003.gguf` | 10.9 MB + 49.8 GB + 12.2 GB = **61.9 GB (57.7 GiB)** | speed alternative of #2 (plan §4 T4 row) |

Sizes and sha256 from `https://huggingface.co/api/models/REPO/tree/main/<dir>` (`lfs.oid`), revision from
`https://huggingface.co/api/models/REPO` (`sha`), all baked into `models.sh`. Nemotron-3-Super-120B (plan §4 T5) stays a
fallback, not queued. Disk: `zroot/data/local-ai` 1.6 TB free before the queue (86 GB used).

- 06:55:11 `flashnext` shard 1 `VERIFIED_OK` (10 946 624 B); shard 2 running at ~10 MB/s (ETA ≈ 09:30 for the model, ≈ 13:30
  for the whole queue). `git fetch` of llama.cpp master (07:06–07:13, 240 MB) shared the link for a few minutes.
- 08:36 shard 2 `VERIFIED_OK` (sha256 of 49.8 GB: 9 min, PCH 93 °C, cap 2400 — the first sign of results-t1.md §3.3). Shard 3
  downloading 08:36–10:24 across the 09:49 reboot and the 10:04 power-off (`curl --continue-at -` resumed both times; each
  queue restart re-hashed the finished shards — fixed 10:24: markers in `models/.verified/`, `verify-slow.py` duty-cycled
  hashing, `lockf` on the queue; details in results-t1.md §3.3). Shard 3 verified 10:29–10:4x by the closed-loop hasher
  (PCH 73–85 °C, ~50 MB/s effective). `qwen122b` (78.6 GB) is the first file hashed with the owner's 40 s / 15 s defaults.
- **13 Sep 11:59–12:05 — first real `verify-slow.py` 40/15 run, verdict: too hot at full clocks, and it hashed the wrong thing.**
  curl ended shard 2 early at 40.98 of 49.67 GB (short read, like Q8 yesterday); `fetch()` cannot see curl's exit status
  behind the progress pipeline and went straight to `verify NAME.part`. verify-slow on the 38.2 GiB `.part` at ~500 MB/s:
  first 40 s burst PCH 77 → 96 °C, then **SAFETY pauses at 100 °C at 12:01:05, 12:02:09, 12:03:08, 12:04:12** (each 25–30 s
  back to 85) — and 100 °C is exactly the watchdog's HOT threshold, so it fired too: `HOT … pch 100 C -> cap 2200 MHz`
  (12:04:11), recovery 12:06:27 → 5300 by ~12:08. Killed the hash at 12:05:3x (32.6/38.2 GiB, `VERIFY_FAIL` size) — it could
  only have failed. Fixes: (1) `download.sh verify()` fails immediately on a size mismatch, no hash; (2) verify-slow safety
  defaults **88/78 °C** (`VERIFY_PCH_HI/LO` still override) so the verifier throttles itself under the watchdog's 90 °C turbo
  band and never costs CPU clocks elsewhere; burst/cool stay 40/15 (the safety net now does the pacing: expect ~25 s bursts).
  The q8 sweep's `igpu29` config waited on `wait-no-verify.sh` the whole time, as designed. Shard 2 resumes on the queue's
  next pass (download.sh continued with shard 3 first).

- **13 Sep 13:31 — verification yields to E2E tasks.** `verify-slow.py` pauses while `~/local-ai-runs/e2e.busy` exists (set by
  `e2e-test.sh` for the duration of a task): under GPU load the PCH already sits at ~80 °C, so the 88/78 pacing degenerated to
  ~5 % duty and still pushed the watchdog band once (cap 2400 under the running c task). Hashing now happens in the gaps between
  tasks (`wait-no-verify.sh` holds the next task meanwhile). Shard 3 of qwen122b verified OK at 12:59 (27 GiB in 3.7 min, PCH max
  89 °C); shard 2 (46.3 GiB, complete at 13:18) waits for the first gap; then the `qwen122b-iq4` download starts.

## 1. Build for Flash-Next — llama.cpp master b10936 + chunked-staging patch (`build-vulkan-master`, 07:13–07:17)

`asgard/build-vulkan-master.sh` (new): `git fetch --tags origin` in the v0.4.0 tree, `git worktree add ../llama.cpp-master
b10936` (newest release tag, 12 Sep 2026, commit `790cf51aa`), `patches/0001-vulkan-chunk-staging-transfers.patch` applies
cleanly (`git apply --check`), same cmake as `build-vulkan-2.sh` plus `-DLLAMA_BUILD_TESTS=ON`, targets `llama-server` and
`test-backend-ops`; ccache made it a 4-minute build at nice 19 (`~/local-ai-runs/build-vulkan-master.log`). The v0.4.0 tree
and `build-vulkan-2` (the T0 profile's binary) are untouched. Selection: `models.sh` `MODEL_BIN` (set for `flashnext`),
`serve.sh` `B=${B:-${MODEL_BIN:-build-vulkan-2}}` — `B=` in the environment still wins, so any model can be A/B-ed on either build.

Sanity (07:18, GPU still pinned at 1035 MHz, so absolute numbers are ~4× low — only the comparison with `build-vulkan-2`
under the same pin counts): `B=…master ./start.sh vram` → UP 17 s, **14 107 MiB** (v0.4.0: 14 099), `GEN=256 bench.py`
depth 64 **tg 16.19 t/s** (v0.4.0 07:12: 15.18), depth 4 096 tg 15.68, pp 162 t/s. No regression; the two builds are
interchangeable for the Qwen3.6 family. `test-backend-ops test -b Vulkan0` of the master build started 07:20 in the
background (`~/local-ai-runs/test-backend-ops-master.log`; the 11 Sep gate on v0.4.0 passed 0 FAIL but aborted at the
768 MiB f32 `MUL_MAT_ID_FUSION` upload — the pinned-allocation cap that the staging patch chunks, so this run should go
through) — **passed, §1.1**.

Open before the first Flash-Next load: (a) QSA sparse attention on Vulkan (#28105 open) — watch for CPU fallbacks or
`unsupported op` at load; (b) the PLE n-gram table (~27 GiB, `get_rows` host-side) must stay in CPU RAM
(`--override-tensor`), token_embd on Vulkan0 to dodge the pinned-allocation poisoning seen with the iGPU split; (c) ARC cap
16 → 8 GiB before the fit (plan: "ARC cap ≤ 8 GiB, no dockaws VM" for the 87 GiB file — the dockaws VM this log is written
from runs on tuxi, asgard has no bhyve guest, so the budget is 128 GiB − ARC 8 − OS/Wired for ~78 GiB of host-side weights
+ the KV/compute host buffers; 07:29 picture: 22 GiB Wired of which 16 GiB ARC, 96 GiB Free); (d)
`reasoning_effort` stays at the template default xhigh unless the E2E shows it is too slow — it is a quality knob, not a
serving switch.

### 1.1 test-backend-ops on the master build — passed (07:20–07:44)

`build-vulkan-master/bin/test-backend-ops test -b Vulkan0`: **18 759/18 759 tests passed, 0 FAIL** (3 928 not-supported
cases skipped as usual), `Backend Vulkan0: OK`, 24 min at nice 19 next to the download. The three f32
`MUL_MAT_ID_FUSION(n_mats=128, m=768, k=2048)` cases whose 768 MiB staging upload SIGABRTed the unpatched v0.4.0 build
on 11 Sep pass now — the chunked-staging patch does its job in the master tree too. No `GGML_VK_DISABLE_*` fallback
needed, coopmat2 active. Excerpt: `research/test-backend-ops-master-b10936-2026-09-13.txt`. The master build is
cleared for Flash-Next (functional gate); QSA/PLE ops are exercised only by the real model load (§2).

### 1.2 serve.sh prepared for three-way placements (07:28)

Tensor overrides are first-match in command-line order (`llama-model-loader.cpp` breaks at the first regex hit;
`--cpu-moe`/`--n-cpu-moe` are just `=CPU` overrides pushed in parse order), so `serve.sh` now emits `IGPU_ARGS` **before**
`NCMOE_ARGS` and adds `--override-tensor token_embd.weight=Vulkan0` whenever `IGPU_MOE>0` (the pinned `token_embd` host
buffer, allocated right after the big Vulkan1 one, was the allocation that poisoned every later NVIDIA allocation —
results-t1.md §1). Placements for the T2 fits, all with `--gpu-layers 99` (attention/dense/shared always on the Quadro):

| knobs | experts of layers … | meaning |
|---|---|---|
| `NCMOE=all` | all → CPU RAM | first load, memory ceiling |
| `NCMOE=k` | 0..k-1 → CPU RAM, k..L-1 → Quadro | VRAM + CPU/RAM (the T1 recipe) |
| `IGPU_MOE=i NCMOE=all` | 0..i-1 → iGPU, i..L-1 → CPU RAM | VRAM + iGPU/RAM |
| `IGPU_MOE=i NCMOE=k` (i<k) | 0..i-1 → iGPU, i..k-1 → CPU RAM, k..L-1 → Quadro | three-way |

The iGPU (Vulkan1) buffers live in the same 128 GiB, so `IGPU_MOE` trades CPU compute for iGPU compute, not RAM for VRAM.

### 1.3 Flash-Next tensor inventory from the shard headers (07:30, `asgard/gguf-hdr.py`, header-only so it works on the `.part`)

Shard 1 holds only metadata (0 tensors, `split.tensors.count` 1 224); shard 2 (layers 0–14 so far) — 46.41 GiB in
373 tensors:

| tensor group | count | GiB | types |
|---|---|---|---|
| `per_layer_token_embd.weight` (PLE n-gram table, 320 001 536 rows × 90 B) | 1 | **26.82** | IQ4_NL |
| `blk.N.ffn_{down,gate,up}_exps.weight` (15/14 layers) | 44 | 17.27 | IQ4_NL/Q8_0 down, IQ3_S/IQ4_XS gate+up |
| `token_embd` / `output` | 2 | 0.63 / 0.49 | Q8_0 / Q6_K |
| all dense per-layer weights (attn/GDN/hc/shexp/indexer/ple_key…) | ~320 | ≈ 1.2 | mostly Q8_0 |

Extrapolated to 48 layers: **experts ≈ 55 GiB (≈ 1.15 GiB per layer), dense ≈ 4 GiB, PLE 26.8, embd+output 1.1 → 87 GiB**
= the file total. VRAM side (dense 4 + output/embd 1.1 + KV/compute) leaves room for roughly 8–9 expert layers on the
Quadro → the fit ladder starts around `NCMOE=40` after the `NCMOE=all` ceiling run.

**The PLE table is handled by master's lazy reader** (`TENSOR_READ_LAZY` on `per_layer_token_embd`, `--lazy-mode auto`
default = lazy for marked tensors > 4 GiB): it is placed in the *plain* CPU buffer type (not the pinned host buffer —
`lazy_read::buft()` returns `ggml_backend_dev_buffer_type(cpu_dev)`), the shard is `mmap`-ed `PROT_READ|MAP_SHARED`
with `POSIX_MADV_RANDOM` over the table even under `--load-mode none` (`init_mappings` maps when `lazy.any()`; only
lazy tensors are served from the mapping, everything else is still `read()` into buffers), and rows are faulted in on
demand → the 26.8 GiB never becomes resident, at the price of page faults on first touch of each n-gram row (ZFS
`primarycache=metadata` on the dataset means each fault is a 128 KiB record read from NVMe that is *not* kept in ARC —
the page cache keeps the 4 KiB page as Inactive memory; a long first prompt will show this as extra pp time). Sweep
knob: `--lazy-mode off` (table resident, +27 GiB host, faster lookups) **must** be paired with `--no-host`, because a
resident input-layer tensor takes the pinned host buffer type first (`make_cpu_buft_list` puts the Vulkan0 host buft
before plain CPU; `--override-tensor …=CPU` re-selects from the same list, so it does not help) and a 27 GiB pinned
allocation is exactly the failed-`vkAllocateMemory` case we must never trigger.

### 1.4 Qwen3.5-122B-A10B tensor inventories from the shard headers (14 Sep 08:15, `gguf-hdr.py` on shards 2+3; shard 1 = metadata only, 0 tensors)

Architecture (shard-1 metadata, `qwen35moe`): **49 blocks = 48 model layers + 1 `nextn` MTP block** (`nextn_predict_layers 1`,
`blk.48.nextn.eh_proj/enorm/hnorm/shared_head_norm`), hidden 3 072, 256 experts × 8 used + 1 shared (expert FFN 1 024),
`full_attention_interval 4` → 12 full-attention layers (+1 in the MTP block = 13 `attn_q/k/v/output` tensors), the other 36
are Gated-DeltaNet/SSM blocks (`attn_qkv`, `attn_gate`, `ssm_out/alpha/beta/conv1d`), **2 KV heads × 256** in the attention
layers, context 262 144. Every block has expert tensors, the MTP block included → `--n-cpu-moe k` counts blocks 0..k-1.

| tensor group | n | UD-Q4_K_XL `qwen122b` GiB (types) | UD-IQ4_XS `qwen122b-iq4` GiB (types) |
|---|---|---|---|
| `blk.N.ffn_down_exps` | 49 | 25.37 (Q5_K, Q6_K) | 19.76 (IQ4_XS, Q4_K, Q6_K) |
| `blk.N.ffn_gate_exps` + `ffn_up_exps` | 98 | 41.54 (Q4_K, Q5_K) | 31.74 (IQ3_S, IQ4_XS, Q3_K) |
| **experts total** | 147 | **66.90 = 1.365 GiB / block** | **51.50 = 1.051 GiB / block** |
| `attn_qkv` / `attn_gate` / `ssm_out` (36 GDN blocks) | 108 | 1.34 / 0.90 / 0.90 (Q8_0) | same |
| `attn_q` / `attn_output` / `attn_k` / `attn_v` (13 attention blocks) | 52 | 0.65 / 0.32 / 0.02 / 0.02 (Q8_0) | same |
| `token_embd` / `output` | 2 | 0.75 / 0.75 (Q8_0) | 0.75 (Q8_0) / 0.58 (Q6_K) |
| shared experts `ffn_*_shexp` (3 × 49), routers, norms, ssm small tensors, nextn | ~390 | ≈ 0.7 | ≈ 0.7 |
| **everything but experts** | 752 | **6.34** | **6.17** |
| **TOTAL** | 899 | **73.23** | **57.66** |

VRAM side at `NCMOE=all`: dense ≈ 5.6 GiB (the 0.75 GiB `token_embd` stays in host RAM as the input layer) + **q8_0 KV for 12
attention layers at 262 144 ctx ≈ 3.2 GiB** (2 heads × 256 × K+V × 1.06 B × 262 144 × 12; the GDN blocks keep only a small
recurrent state) + compute buffers ≈ 1–1.5 GiB → ≈ 10.3 GiB, i.e. **≈ 6 GiB headroom ≈ 4 Q4_K_XL blocks (k ≈ 44–45 of 49) or
≈ 6 IQ4_XS blocks (k ≈ 42–43)**. Fit ladders in `t2-chain1.sh`: `qwen122b all 47 45 44 43 42`, `qwen122b-iq4 all 46 44 43 42
41 40` (memory-only steps). Host side: 67 GiB (Q4_K_XL) / 52 GiB (IQ4_XS) of experts resident with `--load-mode none` + the
8 GiB prompt cache → fits the 128 GiB box with 40–55 GiB to spare even at k=all (ARC is capped, results-t1.md §3.2).

Speed expectation before measuring (for the "how much does T2 cost" question): 10 B active parameters per token, of which
≈ 9 B are experts read from DDR4 at every token — ≈ 5 GB (Q4_K_XL) / 4 GB (IQ4_XS) of expert weights per token over the
~35–40 GB/s the 4-DIMM DDR4-2933 delivers in practice → **≈ 7–8 t/s (Q4_K_XL) / 9–10 t/s (IQ4_XS) tg ceiling at k≈all**,
before the MTP draft (`--spec-type draft-mtp`, one extra predicted token per step, verified in one forward pass — on a
CPU-bandwidth-bound MoE this can be worth 1.3–1.6× because the verification step costs almost the same bandwidth as a
single token). Flash-Next (6 B active, ≈ 3 GB of IQ4 experts per token) should land around 12–14 t/s. Measured values → §2.

## 2. Fits, sweeps, E2E

### 2.1 Flash-Next first load (`fit.sh flashnext all`, 13 Sep 10:41–10:43, GPU healthy, master build b10936)

`NCMOE=all` (every expert tensor in CPU RAM, attention/shared/embeddings on Vulkan0) came **UP in 49 s** — no unsupported-op
abort, no QSA/lazy-read complaint in `serve.out`, pid 12497. Footprint: **VRAM 12 391 MiB** of 16 384 (`--ctx-size 262144`
q8_0 KV), **RSS 57.9 GiB**, Wired 63 GiB, 61 GiB free — i.e. the whole 62.4 GB model is resident (`--load-mode none`, no
mmap), ARC untouched at 769 MiB. Load-time baseline for the fit ladder: with ~4 GiB VRAM headroom the first ladder step is
`NCMOE=46` (≈ 37 experts-layers ≈ 1.1 GiB each? — measure, the 122B numbers in §1 suggest ~0.9 GiB/layer for this quant).
Functional chat request, fit ladder `46 44 42 40`, `IGPU_MOE` three-way variants and `BENCH=bench` sweeps follow when the
GPU is free between the T1 E2E models (T1 has priority per the owner, 10:43). `~/local-ai-runs/fit-flashnext.log`.

### 2.2 Flash-Next fit ladder and first speed row (14 Sep 08:26–08:54, `t1-chain4.sh` step 3/3b) — speed row FAIL-infra (GPU pinned by AC drop #5)

**Fit ladder** (`fit.sh flashnext 44 45 46 47`, GPU healthy at the start, `--ctx-size 262144`, q8_0 KV, THREADS 8):

| `NCMOE` (expert layers on the CPU) | result | VRAM |
|---|---|---|
| all (48; 13 Sep, §2.1) | UP 49 s | 12 391 MiB |
| 47 | UP 66 s | 13 926 MiB |
| 46 | UP 62 s | **15 465 MiB** (over the 15 400 MiB `bestk` ceiling) |
| 45 | **EXITED** after 91 s — `ggml_gallocr_reserve_n_impl: failed to allocate Vulkan0 buffer of size 4212277264` | — |
| 44 | EXITED after 78 s — same 4.2 GB compute-buffer allocation | — |

Read-out: one Flash-Next expert layer on Vulkan0 costs **≈ 1.5 GiB** (12 391 → 13 926 → 15 465), and the graph allocator
wants a **4.2 GB compute buffer** on top of the weights, so the 16 GiB card fits exactly one expert layer with margin
(**`k = 47` is the chain's choice**, `k = 46` leaves < 1 GiB and only works because the compute buffer is not fully
resident). Compared with T1 (`qwen35b-q4` keeps 28 of 48 expert layers on the GPU) this model is 97 % expert-in-RAM by
construction — the "all experts in RAM" regime the T2 speed expectations of §1.4 assume.

**First speed row — pinned, kept as a lower bound** (`sweep.sh flashnext` codebench config `cpuall` = `NCMOE=all SPEC=none`,
UP 08:36:52; **`acpi_acad0: Off Line` 08:36:59 → `On Line` 08:37:09, seven seconds after UP = the first prefill**; GPU
pinned from then on — chain 4's end pin check 08:59:38: 16.24 t/s, 1035 MHz / P2 / mem 6801; results-t1.md §6.2, drop #5):

| row | prompt tokens | pp t/s | generated | tg t/s | wall s |
|---|---|---|---|---|---|
| `cpuall,0` | 90 | 6.1 | 684 | 2.66 | 271 |
| `cpuall,1` | 52 | 9.1 | 2 048 | 2.80 | 738 |
| `cpuall,TOTAL` | — | — | 2 732 | **2.76** | 988 |

`cpu45` then START_FAILED (the k=45 allocation failure above, expected) and the step's AC-drop detector marked the step
suspect; chain 4's end pin check confirmed the pin and the chain stopped there (`exit 2`, by design). What the row does say:

- **2.76 t/s is the *pinned* number**, and the T1-class pin factor (×2.8–2.9, results-t1.md §6.1) does not transfer to a
  model whose experts all live in RAM (the GPU share of a token is much smaller); the healthy expectation from §1.4 stays
  **12–14 t/s** and must be measured after the next cold power-off. The `-pin` rows chain 1 produces are calibration
  material for a T2 pin factor, not results.
- **pp 6–9 t/s on 50–90-token prompts** is the ubatch-512 partial-offload path at its worst (a 90-token prompt streams the
  full expert set for one micro-batch; the cost is per ubatch, not per token) — the `BENCH=bench` rows at 4 096 depth will
  show the streaming throughput properly.
- **PLE page faults are not the bottleneck** (checked 08:45 with `procstat`/`vmstat` on the live server): the lazy
  per-layer-embedding table (`--load-mode none`) takes ~1 major fault per generated token (one NVMe block), i.e. < 1 ms of
  the 360–375 ms per token. Where the rest goes (Vulkan-unsupported ops of the new architecture falling back to the CPU,
  IQ3_S/IQ4_XS dequantisation on the CPU, or simply the pinned GPU) needs a healthy-GPU run — the master build's server log
  does not print graph splits or per-backend buffer sizes, so the `THREADS=16` and `draft-mtp` variants of chain 1 are the
  cheap discriminators.

**Chain plan (v2, deployed 08:56):** `t2-chain1.sh` — pin check (does *not* stop on a pin any more; rows get a `-pin`
suffix and codebench is skipped while pinned) → `fit.sh qwen122b all 47 45 44 43 42` and `fit.sh qwen122b-iq4 all 46 44 43
42 41 40` → `bestk` (largest VRAM ≤ 15 400 MiB) → `BENCH=bench DEPTHS="64 4096"` sweeps `cpuall-none`, `cpuK-none`, `cpuK-mtp`
(and `cpuK-t16` for flashnext) → codebench on the two best configs per model when healthy → end pin check.
`t2-chain2.sh` — waits for chain 1, then E2E phase A (rust + go, all three models, runs even pinned — quality is
regime-independent, `E2E_NOTE` records "GPU PINNED"), phase B (c, cap 8 h) and C (asm, cap 8 h) only on a healthy GPU
(`exit 3` otherwise; `PHASES=BC` restarts them after the cold power-off).

### 2.3 qwen122b would not load at all — the driver's pinned-allocation size windows, root-caused and patched (14 Sep 09:00–09:50, FAIL-infra → fixed)

**Symptom** (`t2-chain1.sh` v2, started 09:00:26 pinned — pin check 16.20 t/s; `fit.sh qwen122b all 47 45 44 43 42`,
`~/local-ai-runs/fit-qwen122b.log`): **every k EXITED** after 48–78 s — 73 × `ggml_vulkan: Failed to allocate pinned memory
(vk::Device::allocateMemory: ErrorOutOfDeviceMemory)` within 30 ms of the first host allocation, then
`alloc_tensor_range: failed to allocate Vulkan0 buffer of size 998244352` → `failed to allocate buffer for kv cache`, with
only 5.7 GiB of the 16 GiB VRAM in use. FAIL-infra, not a model problem — the same failure with the master build, and it
is independent of the GPU pin. Chain 1 and chain 2 were killed at 09:07 for the diagnosis (their orphaned `fit.sh` /
`start.sh` / server too).

**Mechanism** (`-lv 5` + `GGML_VK_MEMORY_LOGGER=1`, then a stand-alone Vulkan probe, `asgard/pinprobe.c` (build line in its header): create buffer →
`vkAllocateMemory` in the host-visible type → bind, ggml-style, N chunks of a given size, then one 952 MiB device-local
allocation):

- With `--cpu-moe` the 147 expert tensors (`ffn_down_exps` q5_K 528 MiB, `ffn_gate/up_exps` q4_K 432 MiB per layer, 48
  layers + nextn) go to the `Vulkan_Host` buffer type, which ggml fills in ≤ 1 GiB chunks (+32 B). **The first chunk is
  810 516 512 B = 773 MiB + 32 B.**
- The NVIDIA FreeBSD driver (595.99.02, RTX 5000) **rejects host-visible allocations whose size falls in
  `[n·256 MiB, n·256 MiB + ≈14 MiB)`** — probed: 256, 768, 772, 773, 3072, 4096 MiB fail; 255, 265, 432, 780, 864, 960,
  1023, 2062, 3086, 4112 MiB succeed (the T0 notes had [256,265), [512,522), [1024,1035), [2048,≈2062) — same family,
  slightly wider today). Not a size budget: 73 × 960 MiB = 70 GiB pinned in one process is fine.
- **One rejected host allocation poisons the process**: after it, the next *device-local* allocation fails too
  (`OUT_OF_DEVICE_MEMORY` for 952 MiB with 10 GiB free) — hence "73 failures" (every later expert chunk, whatever its
  size) and the KV-cache failure. flashnext (IQ4_XS/IQ3_S tensor sizes) simply never hit a window (0 warnings, 62 GB
  pinned); the 11 warnings of the 13 Sep `qwen35b-q8 k=27` load (results-t1.md §4 FAIL-infra #2) were the same mechanism.
- `VK_EXT_memory_priority` (`GGML_VK_ENABLE_MEMORY_PRIORITY=1`) is **not** a way out: with priority set the probe
  **segfaulted inside `vkAllocateMemory`** at 257, 520 and 773 MiB (rc 139, 09:3x, nothing else on the GPU) instead of
  returning an error. Not reproducible at 11:20 with a chain server holding 70 GiB pinned — same sizes then succeed with
  and without priority — so it is state-dependent like the windows themselves; a crash instead of an error is reason
  enough to keep the extension off.
- **The window width is global state, not a constant** (11:20 re-probe while chain 1's qwen122b server held ≈ 70 GiB of
  pinned host memory + 10 GiB VRAM): the exact multiples 256 / 512 / 768 / 1024 MiB still fail, but 257, 520 and 773 MiB
  now succeed — the windows had shrunk from ≈ 12–14 MiB to < 1 MiB. Idle GPU, fresh process: [512, 524), [768, 782),
  [1024, 1038). T0 saw the same history dependence inside one process. Whatever the driver's bookkeeping is, the failing
  set always starts at the multiple of 256 MiB and never reaches 16 MiB above it — hence padding to the *middle* of the
  interval (v2 below) rather than a fixed small offset.
- `--no-host` works (experts go to plain `CPU` 27.8 GiB + `CPU_REPACK` 41.5 GiB, UP 98 s, VRAM 12 375 MiB) but moves the
  prefill to the CPU: pinned pp ≈ 39 t/s, tg 2.3–2.7 t/s. Kept as the documented fallback, not used.

**Fix — `patches/0002-vulkan-pad-host-alloc-windows.patch`** (applied to both trees, `build-vulkan-2.sh` /
`build-vulkan-master.sh` apply 0001 + 0002; rebuilt 09:41 master in 40 s, 10:13 v0.4.0 — its `ggml-vulkan.cpp` takes
24 min with clang, 1 556 s the first time too): in `ggml_vk_create_buffer`, a
host-visible allocation whose size lands in `[n·256 MiB, +16 MiB)` is padded to `n·256 MiB + 24 MiB` (v1; the logical
buffer size is unchanged; `GGML_VK_HOST_ALLOC_PAD=0` disables it, `GGML_VK_MEMORY_LOGGER=1` prints `host-visible size …
padded to …`). **v2 (10:34 master, 11:10 v0.4.0, after the owner's reminder that the T0 limit was "< 256 MiB"):** the
danger zone is `[n·256 MiB, +32 MiB)` and the target is the *middle* of the 256 MiB interval, `n·256 MiB + 128 MiB` — as
far as possible from both the jittering upper edge and the next boundary, ≤ 128 MiB of RAM per affected buffer (2 buffers
for qwen122b, 1 for the T1 profile — nothing in VRAM is padded). Sizes < 256 MiB are never touched (they never fail, T0
§FAIL-infra and today's probe agree); T0's "without priority *every* ≥ 256 MiB allocation fails" does not reproduce with
the ggml-style probe (73 × 960 MiB fine) nor in any server load — the windows are the whole story. Verified 09:43 with `qwen122b NCMOE=all` on the master build: **UP in 56 s, 0
warnings, 68.73 GiB host + 11.57 GiB device** (Vulkan0 12 472 MiB), two chunks padded (773 → 792 MiB, 512 → 536 MiB);
`bestk` VRAM ceiling 15 400 MiB leaves ≈ 2 expert layers (1.37 GiB each) → expect k ≈ 46, not §1.4's 44 (chain 1's
ladders trimmed to `all 47 46 45` / `all 46 45 44`). T1 sanity on the rebuilt `build-vulkan-2` (10:18): `qwen35b-q4`
final profile UP 21 s, **15 167 MiB = unchanged**, one chunk padded (512.76 → 536 MiB — the T1 profile had been sitting
0.76 MiB inside the [512, 524) window all along and got lucky), pinned `bench.py 256`: pp 96.1 / tg 11.48 t/s = the
T1-class pin factor (33 / 2.86). Precise window edges re-probed 10:20: **[512, 524), [768, 782), [1024, 1038)**; the edge
jitters by 1–2 MiB between runs (780 MiB passed at 09:30 and failed at 10:20), hence the 16 MiB danger / 24 MiB safe margins.

**First real speed row — pinned** (`bench.py cpuall-qwen122b-pad-pin 4096`, 09:47, `~/local-ai-runs/sweep-qwen122b.csv`):

| row | prompt_n | pp t/s | tg tokens | tg t/s | wall s |
|---|---|---|---|---|---|
| `cpuall-qwen122b-pad-pin,4096` | 4 001 | **83.2** | 128 | **3.54** | 84 |

GPU-streamed prefill from pinned RAM is 2.1× the `--no-host` CPU prefill (83 vs 39 t/s) and tg is 3.54 vs 2.3–2.7 — all
pinned numbers (1035 MHz / P2); the healthy factor for the experts-in-RAM regime is still unmeasured (T1-class ×2.86 would
give ≈ 10 t/s, the DDR4-bandwidth bound for 5.5 GB/token is ≈ 5–6 t/s — the truth is probably in between and only the
cold power-off will tell). Chains 1 + 2 v2 restarted 10:26 on the patched builds; `fit-qwen122b.log` keeps the four
FAIL-infra rows above a comment line.

### 2.4 Fit ladders and the pinned placement / MTP rows on the patched builds (14 Sep 10:28–11:47, `t2-chain1.sh` v2, GPU pinned)

Fits (`fit.sh ALL=1`, memory only; VRAM after the load; `bestk` ceiling 15 400 MiB — a load that ends above it dies on the first
4K request, results-t1.md §5.1). All loads: **0** `Failed to allocate pinned memory` warnings (patch 0002).

| model | file | `all` | k=47 | k=46 | k=45 | k=44 | `bestk` |
|---|---|---|---|---|---|---|---|
| `qwen122b` | UD-Q4_K_XL 73.3 GiB | 12 470 | **15 250** | ✗ (Vulkan0 alloc) | ✗ | — | **47** |
| `qwen122b-iq4` | UD-IQ4_XS 57.7 GiB | 12 549 | **14 794** (probed 11:59, 2nd pass) | 16 007 (> ceiling) | ✗ | ✗ | **47** |
| `flashnext` | UD-IQ4_XS 87.3 GiB | 12 391 (§2.1) | **13 926** | 15 465 (> ceiling) | START_FAILED | — | **47** |

Per expert block: Q4_K_XL ≈ 1.39 GiB, IQ4_XS ≈ 1.15 GiB (qwen122b), flashnext ≈ 1.54 GiB (15 465 − 13 926). `--n-cpu-moe k` moves
the experts of blocks 0…k−1 to RAM; blocks k…47 **and the nextn/MTP block 48** stay in VRAM (49 expert blocks), so k=47 means
"two blocks in VRAM, one of them the MTP head".

Pinned bench rows (`bench.py`, GEN=256, pp t/s / tg t/s; Quadro pinned at 1035 MHz / P2 since AC drop #5 08:37; labels `*-pin`
in `~/local-ai-runs/sweep-*.csv`):

| model | config | depth 64 | depth 4096 |
|---|---|---|---|
| `qwen122b` | `cpuall-mtp-pin` (`draft-mtp,ngram-mod`, all experts in RAM) | 10.3 / **4.66** | 81.1 / **4.20** |
| `qwen122b` | `cpuall-none-pin` | 11.2 / 3.20 | 82.7 / 3.14 |
| `qwen122b` | `cpu47-mtp-pin` (blocks 47 + 48 in VRAM) | 11.0 / **5.91** | 82.3 / **5.60** |
| `qwen122b-iq4` | `cpuall-mtp-pin` | 9.7 / **3.78** | 75.8 / **4.08** |
| `qwen122b-iq4` | `cpuall-none-pin` | 11.1 / 2.27 | 78.4 / 2.31 |
| `flashnext` | `cpuall` codebench, pinned (08:33, §2.2) | — | small tasks **2.76** |

Reading (all pinned; the healthy pass §2.5 re-measures every row without the `-pin` suffix):

1. **MTP pays**: +46 % / +34 % on `qwen122b` (64 / 4096), +67 % / +77 % on `qwen122b-iq4` — the verification batch reuses the
   RAM-streamed expert weights across the draft tokens, which the one-token-at-a-time `none` path cannot.
2. **k=47 vs all with MTP: +27 % / +33 %** for 2 of 49 blocks — far more than their 4 % share of the expert traffic, so most of it
   is the nextn block's experts sitting in VRAM (the draft runs that block for every draft token). The healthy pass adds a
   `cpu48-mtp` row (only block 48 in VRAM) to separate the two effects; if it carries the gain, every MTP model should keep at
   least its nextn block in VRAM regardless of k.
3. **IQ4_XS is slower than Q4_K_XL here** despite 21 % fewer expert bytes (3.78 vs 4.66 MTP, 2.27 vs 3.20 none) — the experts-in-RAM
   path is not purely byte-bound in this regime; re-check healthy before drawing conclusions (quality decides anyway, §3).
4. Depth-64 pp of 10–11 t/s is the first-request artefact (cold expert stream); pp at 4096 is 76–83 t/s for both files.
5. Pin factor: unknown for this regime until §2.5 (T1-class ×2.86 would put `cpu47-mtp` near 16 t/s; the DDR4-bandwidth bound
   for ≈ 5.5 GB/token is 5–8 t/s, so the truth is probably between 8 and 12 t/s).

Chains stopped 11:47 for the owner's cold power-off (flashnext pinned bench rows skipped; the 08:33 rows stand); asgard back
11:50, patch 0002 v2 confirmed at runtime (11 host-visible buffers padded to `n·256 + 128 MiB`, ops.md), healthy pass started 11:55.

*Postscript 12:20:* the 11:55 "healthy pass" never was one — **AC drop #6 at 11:53:16** (the first load after boot, at
llama-server's built-in all-experts warm-up) had re-pinned the GPU before the chain's pin check (16.23 t/s, 1035 MHz / P2).
Chains stopped 12:03 right after the iq4 k=47 probe (**14 794 MiB**, `bestk` 47 for all three models). Two software levers
were added — `--no-warmup` in serve.sh and the gap-free `ramp.py` before every first request (results-t1.md §6.2 amendment
11:53–12:20) — and the healthy pass restarts after cold power-off #7 (§2.5).

*Postscript 12:30:* cold power-off #7 released the pin (pin check 12:18: 61.2 t/s HEALTHY), and **AC drop #7 at 12:22:03** —
four seconds into the first partial-offload ramp, a ≤ 256-token step — pinned it again. Seven of seven first partial-offload
prefills tripped the adapter; none ever did in the pinned regime. **With this adapter, T2 models always run pinned: the `-pin`
rows above are T2's operating regime, not FAIL-infra** (results-t1.md §6.2 amendment 12:16–12:30). Chains restarted 12:25 as
the *pinned continuation*: chain 1 adds only the missing rows (`cpu48-mtp-pin`, iq4 `cpu47-{mtp,none}-pin`, flashnext
`cpu47-{mtp,none,t16}-pin`), chain 2 runs E2E phases A/B/C pinned and a phase D pinned codebench per model (the report
metric). Healthy T2 numbers need a hardware fix (240 W adapter / jack) first; the T1-class pin factor ×2.86 is the
extrapolation until then.

### 2.5 Complete pinned placement / spec / threads table — the T2 operating regime (14 Sep 12:25–13:22, `t2-chain1.sh` pinned continuation)

All rows GPU pinned (1035 MHz / P2 under load, mem 6801 — the regime every T2 model lands in within seconds of a healthy boot, §2.4
postscript 12:30). `bench.py`, GEN=256, values pp t/s / tg t/s; `~/local-ai-runs/sweep-*.csv`. `k` = `--n-cpu-moe`: expert blocks
0…k−1 in RAM; `all` = 49/49 in RAM, k=48 = only the nextn/MTP block 48 in VRAM, k=47 = blocks 47 + 48 in VRAM (the `bestk`).

| model (file) | k | spec | thr | depth 64 | depth 4096 | VRAM after load |
|---|---|---|---|---|---|---|
| `qwen122b` (UD-Q4_K_XL 73.3 GiB) | all | `draft-mtp,ngram-mod` | 8 | 10.3 / 4.66 | 81.1 / 4.20 | 12 470 |
| `qwen122b` | all | none | 8 | 11.2 / 3.20 | 82.7 / 3.14 | 12 470 |
| `qwen122b` | 48 | MTP | 8 | 11.2 / 4.76 | 81.8 / **5.43** | ≈ 13 9xx |
| **`qwen122b`** | **47** | **MTP** | 8 | 11.0 / **5.91** | 82.3 / **5.60** | **15 250** (15 572 after a 4K request) |
| `qwen122b-iq4` (UD-IQ4_XS 57.7 GiB) | all | MTP | 8 | 9.7 / 3.78 | 75.8 / 4.08 | 12 549 |
| `qwen122b-iq4` | all | none | 8 | 11.1 / 2.27 | 78.4 / 2.31 | 12 549 |
| **`qwen122b-iq4`** | **47** | **MTP** | 8 | 11.1 / **4.94** | 77.2 / **5.21** | **14 794** |
| `qwen122b-iq4` | 47 | none | 8 | 10.0 / 2.45 | 80.1 / 2.43 | 14 794 |
| `flashnext` (UD-IQ4_XS 87.3 GiB) | all | none (codebench, §2.2) | 8 | small tasks 2.76 | — | 12 391 |
| `flashnext` | 47 | `draft-mtp` | 8 | START_FAILED — **the file has no MTP layers** (`context type MTP requested but model doesn't contain MTP layers`; not infra) | | |
| `flashnext` | 47 | none | 8 | 13.3 / 2.69 | 74.6 / 2.50 | 13 926 |
| **`flashnext`** | **47** | **none** | **16** | 12.9 / **3.32** | 78.6 / **2.83** | 13 926 |

Readings (pinned; the healthy factor is unmeasurable with this adapter — T1-class ×2.86 is the extrapolation, i.e. ≈ 16 / 15 / 9 t/s
for the three bold configs):

1. **The nextn block is the k=47 gain.** k=48 (only block 48 in VRAM) already gives 5.43 t/s at depth 4096 vs 4.20 for `all` (+29 %);
   adding block 47 brings 5.60 (+3 %). The MTP draft runs the nextn block for every draft token, so its experts in VRAM remove the
   draft's RAM round-trip. **Rule for MTP models with experts in RAM: keep at least the nextn block on the GPU** (k ≤ 48), whatever k.
   At depth 64 the picture is noisier (4.76 vs 4.66 vs 5.91) — the first-request artefact dominates short rows.
2. **MTP is worth +34–46 % (Q4_K_XL) and +77–114 % (IQ4_XS)** over `none`; the IQ4 file gains more because its `none` path is slower.
3. **IQ4_XS is not faster than Q4_K_XL here** at equal k and spec (5.21 vs 5.60 at 4096, 4.94 vs 5.91 at 64) despite 21 % fewer expert
   bytes — the RAM-streaming path is not byte-bound in the pinned regime (PCIe/latency-bound); the Q4_K_XL file has better quality
   odds, so the iq4 file needs a quality win in §3 to matter.
4. **flashnext:** no MTP head in the UD-IQ4_XS file → `none` only; `THREADS=16` gives +23 % at depth 64 / +13 % at 4096 (the only T2
   model that gains from 16 threads — its 51B n-gram table is a CPU-side lookup). Slowest of the three (2.8–3.3 t/s pinned).
5. Prefill 75–83 t/s at depth 4096 for all three (GPU-streamed experts from pinned RAM); depth-64 pp 10–13 t/s is the cold first request.

E2E configs chain 2 uses for §3 (`bestk` + `bestspec`): `qwen122b k=47 draft-mtp,ngram-mod`, `qwen122b-iq4 k=47 draft-mtp,ngram-mod`,
`flashnext k=47 none` (THREADS stays 8 in the E2E — the t16 gain arrived after chain 2's config was fixed; noted for the freeze).
Chain 1 ended 13:22 (`T2_CHAIN1_DONE`, end pin check 15.09 t/s PINNED); chain 2 phase A started 13:25.

## 3. E2E coding tasks — quality first (`t2-chain2.sh`, 14 Sep 13:25 →, all runs GPU pinned ≈ 5 t/s)

Same harness and verifiers as T0/T1 (`e2e-all.sh` → `e2e-test.sh` drives qwen-code headless against the running server; independent
`verify-*.sh`; `scoreboard.py`). Configs: `qwen122b k=47 draft-mtp,ngram-mod`, `qwen122b-iq4 k=47 draft-mtp,ngram-mod`, `flashnext k=47
none`. Wall times are **pinned-regime** (the T2 operating regime with this adapter, §2.4/§2.5); quality is regime-independent.
Classification: **PASS-score** (all functional checks pass; a missed spec-only check is noted), **FAIL-task-score** (a functional check
fails — the program is wrong), **FAIL-infra** (cut by cap/crash/outage — not a quality signal).

### 3.1 Phase A — rust + go

| model | task | wall | verdict | class | what happened |
|---|---|---|---|---|---|
| `qwen122b` k=47 MTP | rust | 1 012 s (17 min; 10 turns, 26K ctx, tg 3.8 t/s aggregate, 59.8 % draft acceptance) | 4/5 (build ✓ test ✓ signature ✓ nodeps ✓, **round-trips 15/18**) | **FAIL-task-score** | `main()` uses `read_line` → only the **first line** of stdin is reversed; the spec says "reads all of stdin, strips one trailing newline". Multi-line inputs (`ab\ncd\n` → got `ba`, want `dc\nba`) fail. `reverse()` itself is right (Unicode by chars, 4 unit tests incl. Polish). A spec-reading slip, the opposite of the T1 winner's spec-only miss (T1 q4: 18/18 round-trips, signature not `pub`). |
| `qwen122b` k=47 MTP | go | 1 871 s (31 min; 12 turns, 36K ctx, tg 4.6 t/s) | 4/5 (build ✓ vet ✓ test ✓ nodeps ✓, **comparisons 46/47**) | **FAIL-task-score** | `bufio.NewScanner(os.Stdin)` line by line with the default 64 KiB token limit → the 6 MB single-line input fails with `token too long`, rc=1, empty output. Same bug as T1's `kat-q4`; the T1 winner used `io.ReadAll`. The spec says "reads all of standard input" — the same all-of-stdin slip as in its rust solution. Tokenising/counting/sorting/ties are all correct (46/47, 256-line test file). |
| **`qwen122b-iq4`** k=47 MTP | rust | 984 s (16 min; 11 turns, 25K ctx, tg 3.6 t/s) | **PASS 5/5** (18/18 round-trips, `pub fn reverse`, 4 tests, no deps, no unsafe) | **PASS-score** | `io::stdin().read_to_string` + `strip_suffix('\n')` — reads all of stdin, exactly the spec. The first fully clean T2 result; same weights as `qwen122b`, different quantisation, different sampling path → the two files are *not* interchangeable on a single task (one sample each; see the caveat in §3.3). |
| `qwen122b-iq4` k=47 MTP | go | 2 016 s (34 min) | 4/5 (build ✓ vet ✓ test ✓ nodeps ✓, **comparisons 46/47**) | **FAIL-task-score** | The identical `bufio.Scanner` 64 KiB bug as `qwen122b` (6 MB input → rc=1, empty output). Both quantisations of the 122B model reach for `bufio.Scanner` on "read all of stdin" in Go. |
| **`flashnext`** k=47 none | rust | 1 895 s (32 min; 8 turns, tg ≈ 2.5 t/s) | **PASS 5/5** (18/18 round-trips, 0 tool errors) | **PASS-score** | Clean first attempt; slowest wall of the rust runs because of its 2.5 t/s pinned tg, but the fewest turns (8). |
| `flashnext` k=47 none | go | **cut at 3 833 s** (64 min) by the owner's 17:14 power-off (`qwen rc=143`, 3 requests / 6 102 tokens done) | build ✓ vet ✓ nodeps ✓, **comparisons 47/47**, no test file yet → 4/5 | **PASS-functional, FAIL-infra on the unit-test check** | The program on disk was already complete and correct on all 47 comparisons (6 MB input included — it did not fall into the Scanner trap); the model was still working (no `main_test.go`) when the run was killed. Not a quality failure; a rerun would only settle the unit-test spec check. |

**Phase A summary** (functional failures are what the ranking rule counts; spec-only misses noted):

| model | rust | go | functional failures | pp in / tg out t/s (pinned = operating regime; healthy never measured) | pins the GPU? | notes |
|---|---|---|---|---|---|---|
| `qwen122b` UD-Q4_K_XL | 4/5 (first line only) | 4/5 (Scanner 64 KiB) | **2** | k=47 MTP: **82 / 5.9** (depth 64) · 82 / 5.6 (depth 4 096); codebench §3.2 | **always** — 5/5 T2 loads (drops #5–#8) | both are "reads all of stdin" slips |
| `qwen122b-iq4` UD-IQ4_XS | **PASS** | 4/5 (Scanner 64 KiB) | **1** | k=47 MTP: 77 / 4.9 · 77 / 5.2 | **always** | |
| `flashnext` UD-IQ4_XS | **PASS** | functional PASS (47/47), cut before tests | **0** (+1 FAIL-infra check) | k=47 none, 16 thr: 79 / 3.3 · 79 / 2.8 (no MTP layers in the file) | **always** (drop #5 was its first load) | the only T2 model with no functional failure so far |
| T1 winner `qwen35b-q4` (reference) | 4/5 spec-only | PASS | 0 | 831 / 32.5 healthy → 96 / 11.0 pinned | can (3 of 7 drops), not every load | results-t1.md §6 |
| T0 winner `qwen35b` (reference) | PASS | PASS | 0 | 1 362 / 61.5 healthy → 294 / 16.0 pinned | never (all-VRAM) | results-t0.md §4 |

Reading after phase A: on the two short tasks the 122B model is *not* better than the 35B T1 winner — it is worse (2 and 1 functional
failures vs 0), with a recurring pattern (it does not honour "reads all of stdin"). `flashnext` is clean so far. Phase B (c task) and the
phase D pinned codebench decide; phase C (asm) is skipped by default — at 2.5–5.6 t/s every asm run would end at the 8 h cap
(the T1 winner needed 240K tokens in 4 h), three FAIL-infra rows for a day of runtime (`PHASES=DBC` re-enables it).

### 3.2 Phase D — small-task output t/s at each model's E2E config (`codebench.py LABEL 2`, thinking on, greedy, 2 048-token cap per answer, GPU pinned)

The report metric ("speed input and output tok/s" of the final table) at the T2 operating regime; same two coding prompts as the
T0/T1 `*-final` rows. Chain 2 `PHASES=DB`, restarted 17:44 on the GPU pinned by drop #8 (17:37:45, the turbo-off experiment).

| label (sweep-MODEL.csv) | model / config | tokens | wall s | **tg t/s** | pp t/s (48–51-token prompts) | bench rows at the same config (§2.5, depth 64 / 4 096) | note |
|---|---|---|---|---|---|---|---|
| `cpu47-mtp-pin-code` | `qwen122b` k=47 `draft-mtp,ngram-mod` | 4 096 | 949.3 | **4.31** | 8.1 / 9.0 | 5.91 / 5.60 | 17:51–18:07; both answers hit the 2 048-token cap still inside the thinking block (8 624 / 6 608 reasoning chars, 0 content chars) — real-prompt tg is 25 % below the bench tg (long reasoning ⇒ fewer accepted MTP/n-gram drafts) |
| `cpu47-mtp-pin-code` | `qwen122b-iq4` k=47 `draft-mtp,ngram-mod` | 4 096 | 1 174.4 | **3.49** | 8.1 / 8.6 | 4.94 / 5.21 | 18:12–18:40; both answers capped inside thinking (8 194 / 6 048 reasoning chars, 0 content) — 19 % slower than qwen122b (3.49 vs 4.31) on the same prompts although its bench tg was only 12–16 % lower; IQ4_XS dequant is the bottleneck on real prompts too (§2.4 point 3) |
| `cpu47-none-pin-code` | `flashnext` k=47 `none`, 16 thr | 2 732 | 922.7 | **2.96** | 8.6 / 9.7 | 3.32 / 2.83 | 18:43–19:05; prompt 0 is the only phase-D answer that **finished** (684 tokens: 1 995 reasoning + 606 content chars — the shortest thinker of the three), prompt 1 capped at 2 048 inside thinking (6 892 chars); no MTP layers ⇒ plain decode, 31 % slower than qwen122b |
| `t1-final` (reference) | `qwen35b-q4` k=20, healthy GPU | 3 692 | 117.8 | 31.35 | — | pinned `cpu20-pin` 10.98 | results-t1.md §6.3 |
| `t0-final` (reference) | `qwen35b` all-VRAM, healthy GPU | 3 957 | 65.3 | 60.55 | — | pinned 16.3 | results-t1.md §6.3 |

The pinned prefill of a 50-token prompt at 8–9 t/s (6 s before the first token) is the same host-transfer penalty seen in §2.5
(pp 82 t/s at depth 4 096): the pinned regime slows prompt processing far more than generation.

**Phase D order (pinned, real coding prompts): `qwen122b` 4.31 > `qwen122b-iq4` 3.49 > `flashnext` 2.96 t/s** (pp 8–10 t/s for all
three). Extrapolated healthy (×1.3–1.8, results-t1.md §6.1): ≈ 5.6–7.8 / 4.5–6.3 / 3.8–5.3 t/s. Wall time per answer is what the user
feels: flashnext's shorter reasoning made it the only model to deliver a complete answer inside the 2 048-token cap (238 s) while the
qwen122b files spent the whole budget thinking (≈ 480–600 s each) — the E2E tasks (§3.1, no cap) are the fair comparison for that.

### 3.3 Phase B — c task (`bignum`: arbitrary-precision + − × on stdin lines, Makefile, `--selftest`, strict + sanitizer builds; cap 8 h, GPU pinned)

The hard task of the set: T0's winner scored 4/5 (blank-line echo), T1's winner PASS 5/5 in 54 min at 20 t/s (results-t1.md §3),
three T0 candidates failed it outright. Verifier `verify-c.sh` (make, `make test`, `-Werror`, ASan/UBSan, 420 arithmetic vectors up to
3 000 digits, malformed/blank lines, empty input).

| model | wall | turns / ctx max / tg t/s (aggregate, per-request min–max) | verdict | class | what happened |
|---|---|---|---|---|---|
| **`qwen122b`** k=47 MTP | **5 869 s (98 min**, 18:58–20:40) | 39 turns / 54.0K / **3.9** (2.2–5.2); pp 48 t/s aggregate over 104K prompt tokens; 59.7 % draft acceptance | **PASS 5/5** (functional 4/4, spec 1/1): make ✓ `make test` ✓ strict ✓ ASan/UBSan ✓ selftest-under-ASan ✓ **420/420 arithmetic** ✓ malformed/blank ✓ empty ✓ | **PASS-score** | 479-line `bignum.c` (sign + little-endian digit array, `getline` loop — this time it *does* read all of stdin), 40-case `--selftest`, portable Makefile (BSD + GNU make). 39 turns vs the T1 winner's 86: fewer, longer thinking turns (16 shell runs, 9 edits, 7 tool errors — one genuine bug found and fixed by its own ASan run: `s[start + start]` typo in `bigint_new`). Wall 1.8× the T1 winner's at ¼ of its tg. |
| **`qwen122b-iq4`** k=47 MTP | **8 488 s (141 min**, 20:47–23:08) | 40 turns / 63.6K / **3.6** (1.8–6.0); pp 45 t/s aggregate over 114K prompt tokens; 65.1 % draft acceptance | **PASS 5/5** (functional 4/4, spec 1/1): all eight verifier checks ✓, **420/420 arithmetic** ✓ | **PASS-score** | 760-line `bignum.c` (sign + `unsigned char` digit array, 22 asserts, malloc/free 7/31 — helper-heavy), 40 turns like its Q4_K_XL sibling (19 shell runs, 6 edits, 4 tool errors); found and fixed its own parser bug (`len_a` computed after `p` had moved past the operator) with printf debugging. 1.45× the Q4_K_XL wall for the same score: same turn count, 7 % lower tg and longer answers (21.5K vs 14.2K generated tokens). Accepts `2 * 3` with extra spaces where Q4_K_XL printed `error` — both allowed by the verifier. |
| **`flashnext`** k=47 none, 16 thr | **27 807 s (7 h 43 min**, 23:11–06:58, 17 min under the 8 h cap) | 45 turns / 107.6K / **2.5** (2.3–2.6); pp 32 t/s aggregate over 43K prompt tokens; no drafts | **PASS 5/5** (functional 4/4, spec 1/1): all eight verifier checks ✓, **420/420 arithmetic** ✓ | **PASS-score** | 707-line `bignum.c` written in **one shot** (turn 2, after a 2-hour / ~17K-token first think that ended in a mere toolchain check), 25 asserts, malloc/free 2/8, portable Makefile fixed once (an environment `CFLAGS` had dropped `-std=c11`). Then 40 turns of *its own* verification: a differential fuzzer against Python (`/tmp/fuzz.py`, 3 761 cases, 0 mismatches) under ASan and UBSan, leak balance, BSD-vs-GNU make matrix, 10 000-digit operands, and a 7K-token final report. **66.9K generated tokens** — 4.7× `qwen122b`'s 14.2K for the same 5/5: correct, but verbose and slow (2.5 t/s, no MTP layers). |
| T1 winner `qwen35b-q4` (reference, healthy GPU) | 54 min | 86 turns / 110K / 20.1 (16.7–26.1) | PASS 5/5 | PASS-score | results-t1.md §3 |
| T0 winner `qwen35b` (reference, healthy GPU) | 43 min | 117 turns / 135K / 34.8 | 4/5 (420/420 arithmetic, blank lines echoed) | FAIL-task-score near-miss | results-t0.md §4 |

Reading after phase B: **all three T2 models PASS the c task 5/5** (T0's winner got 4/5, T1's winner 5/5) — the hard task is where the
big models earn their size, and none of them looped (39–45 turns vs 86–117 for the 35B models). Phase A's failures were the same
"reads all of stdin" slip on trivial programs; here all three read the whole input correctly. Wall time is where they differ:
`qwen122b` 98 min, `qwen122b-iq4` 141 min, `flashnext` 463 min — flashnext generated 4.7× the tokens (66.9K vs 14.2K) at 60 % of
the speed (2.5 vs 3.9 t/s): it thinks for hours and then verifies far beyond the spec. Quality-wise phase B is a three-way tie, so
the T2 verdict (§4) rests on rust + go, where one sample each gave qwen122b 2 / iq4 1 / flashnext 0 functional failures — hence
chain 3's second sample (§3.4).
