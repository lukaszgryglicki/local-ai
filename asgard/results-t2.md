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

## 2. Fits, sweeps, E2E

### 2.1 Flash-Next first load (`fit.sh flashnext all`, 13 Sep 10:41–10:43, GPU healthy, master build b10936)

`NCMOE=all` (every expert tensor in CPU RAM, attention/shared/embeddings on Vulkan0) came **UP in 49 s** — no unsupported-op
abort, no QSA/lazy-read complaint in `serve.out`, pid 12497. Footprint: **VRAM 12 391 MiB** of 16 384 (`--ctx-size 262144`
q8_0 KV), **RSS 57.9 GiB**, Wired 63 GiB, 61 GiB free — i.e. the whole 62.4 GB model is resident (`--load-mode none`, no
mmap), ARC untouched at 769 MiB. Load-time baseline for the fit ladder: with ~4 GiB VRAM headroom the first ladder step is
`NCMOE=46` (≈ 37 experts-layers ≈ 1.1 GiB each? — measure, the 122B numbers in §1 suggest ~0.9 GiB/layer for this quant).
Functional chat request, fit ladder `46 44 42 40`, `IGPU_MOE` three-way variants and `BENCH=bench` sweeps follow when the
GPU is free between the T1 E2E models (T1 has priority per the owner, 10:43). `~/local-ai-runs/fit-flashnext.log`.
