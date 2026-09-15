# asgard T2 report — the `best` profile (2026-09-13 → 2026-09-15)

> **FINAL (15 Sep 12:15)** — the second rust/go sample (`t2-chain3.sh`) finished 11:08, the decision is in §6, the frozen configuration
> in §8. `STATUS.md` is the restart sheet; `results-t2.md` has every number; daily use: `../asgard-deployment/README.md`.

**Result:** **`flashnext` (Qwen3.8-Flash-Next UD-IQ4_XS) is the T2 `best` profile** — the only candidate with **0 functional failures in
5 coding runs** (rust ×2, go ×2, c). Both Qwen3.5-122B quantisations failed the go task in 4 of 4 runs on the same bug (`bufio.Scanner`
64 KiB default vs a 6 MB line) and `qwen122b` also mis-read stdin in one rust run (3 and 2 failures). Speed with the GPU pinned (the T2
operating regime with this adapter): flashnext **3.0 t/s** on real coding prompts (2.5–2.7 in the E2E runs), iq4 3.5, qwen122b 4.3 — all
above the T2 goal (≥ 1.8, ideal > 3). Frozen 15 Sep 11:20; the 122B files were deleted on the owner's order; `sudo service llama-t2 start`.

This is the consolidated report. The chronological working log with every number, log excerpt and dead end is
`results-t2.md`; the T0/T1 reports and logs are `report-t0.md`, `results-t0.md`, `results-t1.md`; the plan is `plan.md`; how
the box is operated is `ops.md`; the live restart sheet is `STATUS.md`.

## 1. What T2 means and what was required

`plan.md` §10 (owner, 12 Sep) defines three serving profiles, each = the tier's best model *by the E2E coding tasks* in its best
configuration *by the sweeps*:

| profile | tier | placement | generation-speed goal (output t/s, session aggregate) |
|---|---|---|---|
| `fastest-vram` | T0 | everything in the 16 GiB Quadro | > 12, never < 10, ideal 15–25 — **frozen 13 Sep: `qwen35b`** |
| `fast` | T1 | VRAM first, overflow to iGPU or CPU RAM | ≥ 6, minimum 4, ideal 7–10 — **frozen 14 Sep: `qwen35b-q4`** |
| **`best`** | **T2** | **as much as fits across VRAM + iGPU + RAM, whichever split is fastest** | **≥ 1.8, minimum 1, ideal > 3** |

Hard requirements kept from T0/T1: the **full native context (262 144 tokens per slot)**, thinking on, q8_0 K and V, flash
attention, no YaRN, the model card's sampling, `--parallel` as high as fits (1 for every T2 model). New for T2: the weights do not
fit the GPU, so the placement itself is a sweep dimension — how many expert blocks stay in VRAM (`NCMOE=k`, the rest streamed from
pinned host RAM by the Vulkan backend), MTP/n-gram speculative decoding on or off, CPU thread count.

**Ranking rule (owner, 14 Sep):** the tier winner is chosen by **coding output quality** on the E2E tasks (functional failures
first, spec-only misses second), speed second; when the GPU is pinned (§7.1) the speed is measured pinned and the healthy value is
*extrapolated*, never guessed as the winner's merit. Verdict vocabulary as in T0/T1: **PASS-score**, **FAIL-task-score** (the run
completed, the program is wrong — a model result), **FAIL-infra** (cut by cap / crash / power-off — never counted against a model).

## 2. The box and the test conditions

Dell Precision 7750: Xeon W-10885M (8C/16T), **Quadro RTX 5000 16 GiB** (nvidia 595.99.02, Vulkan 1.4, `NV_coopmat2`), Intel UHD
P630 iGPU, **128 GiB DDR4**, 4 × KC3000 NVMe, FreeBSD 15.1-STABLE, GELI; the 240 W Dell adapter (owner-confirmed). Two llama.cpp
builds, both with `patches/0001-vulkan-chunk-staging-transfers.patch` (T0) and **`0002-vulkan-pad-host-alloc-windows.patch`
(T2, §7.2)**: `build-vulkan-2` = the POC fork v0.4.0 `5266f24` (T0/T1 profiles, the two Qwen3.5-122B files) and
`build-vulkan-master` = upstream **b10936 `790cf51aa`** (the only tree that knows the `qwen4exp` architecture of Flash-Next;
`models.sh` `MODEL_BIN` selects it per model, `B=` overrides). ZFS ARC capped at **2 GiB** (owner, 14 Sep) so ~110 GiB of RAM
stay free for pinned expert weights; `primarycache=metadata` on the model dataset.

Thermal regime unchanged from T0/T1 (owner's `thermal_policy` turbo band 5.3 → 2.4 GHz by hottest core, no turbo at PCH ≥ 85 °C,
BIOS "Cool"); `telemetry.sh` (5-s CSV, guard at PCH ≥ 108 °C) ran under every test and never fired; `verify-slow.py` pauses model
hashing during E2E tasks. **The GPU was in the EC's power-brake state (SM ≤ 1035 MHz, ≤ 57 W, "pinned", §7.1) for every T2
sweep and E2E run** — partial-offload prefills trip the AC adapter within seconds on a healthy GPU, so with this adapter the
pinned regime *is* the T2 operating regime. Quality is regime-independent; wall times and t/s in this report are pinned unless
marked healthy/extrapolated.

## 3. Method

1. **Download** (`download.sh`, sharded files, sha256 per shard against the HF LFS oid, resumable; `dl-t2-queue.sh`): ≈ 234 GB (93.7 + 78.6 + 61.9) in
   36.5 h on Wi-Fi, 13 Sep 06:55 → 19:24 `QUEUE_DONE` across two reboots and a power-off (results-t2.md §0).
2. **Fit ladder** (`fit.sh MODEL all 47 46 45 …`): `NCMOE=k` = number of expert blocks kept in host RAM (48 layers → `all`
   = every expert in RAM, `47` = one block in VRAM); the smallest k that comes UP with ≤ 15 400 MiB VRAM (leaving room for
   the 262K KV + compute buffers) is the model's E2E placement — **k = 47 for all three** (results-t2.md §2.4–2.5).
3. **Placement / speculative / threads sweep** (`sweep.sh`, `bench.py` at depth 64 and 4 096, 150-s gaps): `draft-mtp,ngram-mod`
   vs `none`, 8 vs 16 threads; winner = highest tg at depth 4 096 (results-t2.md §2.5 — the complete pinned table).
4. **Phase D — `codebench.py LABEL 2`** at each model's E2E config: the two realistic coding prompts of the T0/T1 `*-final`
   rows, thinking on, greedy, 2 048-token cap — the "small-task output t/s" of the final table (results-t2.md §3.2).
5. **The E2E tasks** (`e2e-all.sh` → `e2e-test.sh`, headless qwen-code `--yolo`, 262K context, independent `verify-*.sh`,
   `scoreboard.py`): **rust** (easy, `revstr`), **go** (medium, `wordfreq`, 6 MB single-line input), **c** (hard, `bignum`, 420
   vectors, ASan/UBSan) with caps of 4 h (rust/go) and **8 h (c)** — T2 generates 4–8× slower than T1, the 4-h cap would
   measure speed, not quality. **asm** (hardest, 240K tokens for the T1 winner at 20 t/s) is **not run for T2**: at 3–5 t/s
   every asm run ends at the cap — three FAIL-infra rows for a day of runtime (`PHASES=C` of `t2-chain2.sh` re-enables it).
   rust + go were run **twice** per model (chain 2 phase A, chain 3 phase A2) because one sample per task at the model
   card's temperature is a noisy quality signal; c once (2–3 h per model).

Chains: `t2-chain1.sh` (fits + sweeps), `t2-chain2.sh` (phase A rust/go → phase D codebench → phase B c), `t2-chain3.sh` (phase
A2 second sample) — all detached with `daemon`, AC-drop detector around every step, `t2-stop` marker to end after the current
task. Everything is kept in `/data/ai/<task>-task-<model>/` (run 1 as `….prev-<timestamp>`), `~/local-ai-runs/sweep-<model>.csv`,
`~/local-ai-runs/fit-<model>.log`, `~/local-ai-runs/e2e-<model>.log`.

## 4. Candidates

Shortlist from `plan.md` §4 (T3/T4 rows) — the largest coding-capable MoEs whose expert weights fit 128 GiB of RAM beside a
2 GiB ARC and the KV/compute host buffers:

| name | model | file | why |
|---|---|---|---|
| `flashnext` | **Qwen3.8-Flash-Next** (`qwen4exp`, 125B-A6B: 48 layers, 512 experts × 10 + shared, GDN hybrid, QSA indexer, PLE n-gram table ≈ 27 GiB host-side, MTP head in the architecture but **no MTP layers in this file**) | UD-IQ4_XS, 3 shards, **87.3 GiB** | the newest Qwen coder-class model; needs llama.cpp ≥ b10889 (master build) |
| `qwen122b` | **Qwen3.5-122B-A10B** (MTP head in the file) | UD-Q4_K_XL, 3 shards, **73.3 GiB** | the proven 122B; MTP + n-gram speculative decoding work |
| `qwen122b-iq4` | Qwen3.5-122B-A10B, smaller quant | UD-IQ4_XS, 3 shards, **57.7 GiB** | speed alternative of `qwen122b` (21 % fewer expert bytes) |

Rejected with reasons in `plan.md` §4: Nemotron-3-Super-120B (fallback, never queued), everything > 128 GiB of weights,
non-thinking coder files. The iGPU (Vulkan1) split was measured in T1 and lost to CPU RAM on every row (`igpu20` 16.2 vs `cpu20` 30.7 t/s; results-t1.md §3), so T2
used VRAM + pinned host RAM only.

## 5. Results per model

Five E2E coding runs per model (`e2e-test.sh` + `scoreboard.py`, temperature 1.0, GPU pinned, run-1 projects kept as
`/data/ai/TASK-task-MODEL.prev-20260915-*`, run 2 in `/data/ai/TASK-task-MODEL`). Details and log excerpts: results-t2.md §3.1–§3.4.

| model | rust run 1 / run 2 | go run 1 / run 2 | c | functional failures | codebench tg t/s (pinned) | bench tg depth 64 / 4 096 |
|---|---|---|---|---|---|---|
| **`flashnext`** k=47 none, 16 thr | PASS 5/5 (32 min) / PASS 5/5 (37 min) | FAIL-infra (cut at 64 min by the owner's power-off, 47/47 comparisons functional) / **PASS 5/5** (79 min) | **PASS 5/5** (463 min, 66.9K generated) | **0** | **2.96** | 3.3 / 2.8 |
| `qwen122b-iq4` k=47 MTP | PASS (16) / PASS (20) | 4/5 (34) / 4/5 (32) — `bufio.Scanner` 64 KiB | PASS 5/5 (141 min) | 2 | 3.49 | 4.9 / 5.2 |
| `qwen122b` k=47 MTP | 4/5 (17, read only the first line) / PASS (15) | 4/5 (31) / 4/5 (26) — `bufio.Scanner` 64 KiB | PASS 5/5 (98 min) | 3 | 4.31 | 5.9 / 5.6 |

The c task (bignum with the 1 MB-line stress) is a three-way 5/5 tie and the first T2 result that beats the T0 winner (4/5); it separates
the models only in wall time (flashnext thinks for hours and then verifies far beyond the spec). The short tasks separate them in
correctness: the 122B model's go failure is the same deterministic slip in every run.

## 6. Scoreboard and decision

Owner's ranking rule: coding output quality first, speed second (T2 goal ≥ 1.8 t/s, ideal > 3).

| rank | model | functional failures / 5 | tg pinned (codebench) | healthy estimate (×1.3–1.8, unmeasured) | verdict |
|---|---|---|---|---|---|
| **1** | **`flashnext`** | **0** | 2.96 | 3.9–5.3 | **T2 winner — `best|t2` frozen 15 Sep 11:20** |
| 2 | `qwen122b-iq4` | 2 | 3.49 | 4.5–6.3 | deleted 15 Sep 11:15 (owner) |
| 3 | `qwen122b` | 3 | 4.31 | 5.6–7.8 | deleted 15 Sep 11:15 (owner) |

Decision: `flashnext` — the quality gap is real and reproducible (0 vs 2 vs 3 failures across two independent samples), the speed
difference is 1.2–1.5× and all three sit above the goal even pinned. Owner: "flash wins, so delete other T2 models". The price is wall
time (it generated 4.7× the tokens of qwen122b on the c task); `reasoning_effort` is pinned at xhigh on purpose (owner: thinking on,
effort at maximum). Full reasoning and the freeze record: results-t2.md §4.

## 7. Infrastructure events, root causes and fixes (all FAIL-infra, none counted against a model)

### 7.1 The AC-adapter drop → GPU power-brake pin (drops #5–#8, 14 Sep)

Every T2 load on a healthy GPU ended the same way within seconds of the first partial-offload prefill: `acpi_acad0: Off Line`
(AC lost for ~7 s), the Dell EC asserts the GPU's **hardware power-brake pin**, and the Quadro stays at SM ≤ 1035 MHz / P2 /
≤ 57 W until a cold power-off (`shutdown -p`; warm reboots do not clear it). 8 drops in the log (#3 was the owner's replug); of the 7 spontaneous
ones 4 were T2 loads (#5 flashnext k=all, #6/#7/#8 qwen122b — every T2 load on a healthy GPU, 5 of 5 attempts), 3 T1-class
partial-offload loads (#1, #2, #4: `qwen35b-q4`/`-q8`, NCMOE 20–29), **0 in ~30 h of all-VRAM T0 at the same 100–125 W GPU power** — the trigger is the GPU boosting to ~1950 MHz *while expert weights stream from host RAM*, not the GPU
power alone. The CPU was exonerated by a 0.5-s trace with turbo disabled (drop #8: GPU 1950 MHz / 100.9 W → AC gone 0.6 s later,
CPU at 1.3 GHz). Evidence: `nvidia-smi -q -d PERFORMANCE` "HW Power Braking" counter ≈ all wall time since the drop;
fingerprints `~/local-ai-runs/gpu-fingerprint-{healthy,pinned}.txt`; the full analysis is results-t1.md §6.2 (owner's 240 W adapter
confirmed; suspects: adapter-ID centre pin/jack, adapter transient response, BIOS Peak Shift / AC Adapter Type — an owner BIOS review
is pending). Software levers left would be GPU boost/power caps (`nvidia-smi -lgc/-pl`), which the owner ruled out. `/data/scripts/temp.sh`
now shows `boost-lock: PINNED/none` on its GPU line.

Consequences for T2: the pin costs ×3.8 tg / ×4.6 pp on all-VRAM, ×2.9 / ×8.7 on the T1 profile (both measured); for the
experts-in-RAM regime the factor was **never measured healthy** (every attempt tripped the adapter first) and is estimated at
**×1.3–1.8** for tg (DDR4 bandwidth bounds it, results-t1.md §6.1). All T2 speeds in this report are pinned; the extrapolated
healthy values in §6 use that range.

### 7.2 qwen122b would not load — the driver's pinned-allocation size windows (14 Sep 09:00–09:50, fixed)

Every `qwen122b` fit exited with 73 × `Failed to allocate pinned memory` and a spurious KV-cache failure with 10 GiB of VRAM free.
Root cause (stand-alone Vulkan probe `asgard/pinprobe.c`): the NVIDIA FreeBSD driver rejects **host-visible allocations whose size
falls in `[n·256 MiB, n·256 MiB + ≈14 MiB)`** (edges jitter by 1–2 MiB and shrink with GPU memory state), and one rejected host
allocation poisons the next device-local allocation of the process. ggml's first expert chunk for this file is 773 MiB + 32 B —
inside the window. **`patches/0002-vulkan-pad-host-alloc-windows.patch`**: host-visible sizes in `[n·256 MiB, +32 MiB)` are padded to
`n·256 MiB + 128 MiB` (the middle of the interval, after the owner's reminder that the T0-era limit was "< 256 MiB"); ≤ 128 MiB of
RAM per affected buffer, nothing in VRAM padded, `GGML_VK_HOST_ALLOC_PAD=0` disables. Verified: `qwen122b` UP in 56 s with 0
warnings; the T1 profile turned out to have been 0.76 MiB inside a window all along (unchanged VRAM after the patch).
`VK_EXT_memory_priority` was tried and **segfaults inside `vkAllocateMemory`** at the same sizes — kept off. Details: results-t2.md §2.3.

### 7.3 Flash-Next needs upstream master — `build-vulkan-master` (13 Sep 07:13)

The v0.4.0 fork does not know `qwen4exp`; `build-vulkan-master.sh` builds b10936 in a worktree with both patches, `test-backend-ops`
passed on Vulkan0 (results-t2.md §1.1), and the T0 profile measures the same on both builds (16.2 vs 15.2 pinned t/s at depth 64,
same VRAM). Flash-Next's ~27 GiB PLE n-gram table lives host-side (`get_rows`), its MTP head has no layers in the GGUF (so
`SPEC=none`), and 16 CPU threads beat 8 by 13–23 % on it (results-t2.md §2.5) — the only model where the thread count mattered.

### 7.4 Cuts, crashes and gaps that produced FAIL-infra rows

- **14 Sep 17:14 owner power-off** (to unpin the GPU) cut `flashnext` go at 64 min with the program complete (47/47 comparisons) but
  before its unit-test check → FAIL-infra on that check; re-run in chain 3 (§5).
- **verify-slow / download thermal episode** 13 Sep 11:59–12:05 (PCH 100 °C, watchdog HOT) during the `qwen122b` shard hashing —
  fixed by size-check-before-hash and 88/78 °C pacing; no model result affected (results-t2.md §0).
- The **bhyve VM this log was driven from crashed twice** and asgard was cold-cycled several times (owner) during T2; no chain state
  was lost because every chain is a detached `daemon` on asgard and `STATUS.md` was refreshed at every transition.

## 8. The frozen configuration

`models.sh` `best|t2` → `flashnext` (`NP=1 CTX=262144 SPEC=none NCMOE=47 IGPU_MOE=0 THREADS=16 THREADS_BATCH=16`), and, for daily use,
`/data/local-ai/asgard-deployment/llama-tier.sh t2` (= `sudo service llama-t2 start`):

| item | value |
|---|---|
| model | `Qwen3.8-Flash-Next-UD-IQ4_XS-0000{1,2,3}-of-00003.gguf`, 87.3 GiB; served ids `qwen3.8-flash-next`, `qwen3coder-local` |
| binary | `llama.cpp-master/build-vulkan-master/bin/llama-server` (upstream master ≥ b10889 + patches 0001/0002) |
| placement | `--gpu-layers 99 --device Vulkan0 --fit off --n-cpu-moe 47` → 14.2 GiB VRAM, ~58 GiB pinned host RAM + ~27 GiB lazily mapped n-gram table |
| context / slots / KV | 262 144 × 1, q8_0 K and V, flash-attn on, `--cache-ram 8192`, `--ctx-checkpoints 8`, batch 2048 / ubatch 1024 |
| threads | 16 / 16 (the only model where 16 beat 8, +13–23 %) |
| reasoning | `--jinja --reasoning on --reasoning-budget -1 --chat-template-kwargs {"enable_thinking":true} --reasoning-effort xhigh` |
| sampling | temp 1.0, top_p 0.95, top_k 20, min_p 0, repeat-penalty 1.0 (Qwen thinking-mode card values) |
| misc | `--no-warmup` + client-side soft-start ramp, `--load-mode none`, `--spec-type none`, `--timeout 43200`, API key file, host 10.253.254.1:18080 |
| YaRN x2 | `sudo service llama-t2 start yarn2`: ctx 524 288, `--rope-scaling yarn --rope-scale 2 --yarn-orig-ctx 262144`, KV q4_0, batch 1024/512 — loads (11.2 GiB steady), untested beyond 256K; x4 refused |
| speed | pinned: pp 79 t/s, tg 3.0 (codebench) / 2.5–2.7 (E2E); load 49–57 s; stop needs KILL after 30 s |

## 9. Open items

- **GPU pin** (owner): UEFI review — AC Adapter Type / Peak Shift / jack centre pin (results-t1.md §6.2); until solved every T2 load pins the
  GPU and the healthy-regime T2 speed (§6 estimate) stays unmeasured.
- **asm task for T2** never ran (phase C off: FAIL-infra by cap at ≈3 t/s); run on request with `E2E_CAP` ≥ 8 h.
- Quality sample is 5 runs per model; the tally was consistent across two samples but small.
- Owner: commit `/data/local-ai` (asgard-deployment/README.md + llama-tier.sh, the 15 Sep doc refresh), `git pull` on tuxi; later remove the
  research rc.d `llama` stub + `llama_enable` from rc.conf once the tier services are trusted; delete the c-task scratch in asgard `/tmp`.

## 10. Artifact index

| what | where |
|---|---|
| working log with every number | `results-t2.md` (§0 downloads, §1 build, §2 fits/sweeps/bench, §3 E2E quality, §4 verdict) |
| restart sheet / operations log | `STATUS.md`, `ops.md` (§6 15 Sep bullets) |
| chain scripts + logs | `~/local-ai-runs/t2-chain{1,2,3}.sh`, `t2-chain{1,2,3}.log`, `e2e-MODEL.log`, `sweep-MODEL.csv`, `pincheck-*` |
| E2E projects | `/data/ai/{rust,go,c}-task-MODEL` (run 2) and `…prev-20260915-*` (run 1), each with `summary.txt`; grader `asgard/scoreboard.py` |
| speed tools | `asgard/bench.py`, `codebench.py`, `ramp.py`, `sweep.sh`; telemetry `~/local-ai-runs/telemetry.csv` |
| fixes | `patches/0002-vulkan-pad-host-alloc-windows.patch`, `asgard/pinprobe.c`, `asgard/build-vulkan-master.sh`, `--no-warmup` in `serve.sh` |
| GPU-pin evidence | `~/local-ai-runs/gpu-fingerprint-{healthy,pinned}.txt`, `/var/log/messages` (`acpi_acad0`), results-t1.md §6.2 |
| frozen configuration | `asgard/models.sh` (`best|t2`), `/data/local-ai/asgard-deployment/` (launcher, rc.d stubs, clients, README) |
