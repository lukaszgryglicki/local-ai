# asgard T-1 report — the `fastest-vram` profile (2026-09-11 → 2026-09-12)

**Result: `qwen35b` = Qwen3.6-35B-A3B UD-IQ2_M (unsloth, non-MTP file), whole model + 256K q8_0 KV in the Quadro RTX 5000,
NP=1, `--spec-type none`, `--cache-ram 8192`, patched `build-vulkan-2`.** It won the four-task coding E2E 2/4 + a near-miss
against North-Mini-Code (0/4), Qwen3.5-9B+MTP (1/4) and Gemma-4-26B-A4B (1/4), at 35–46 t/s session aggregate (worst single
request 18 t/s at 230K context) — above the T-1 goal of > 12 t/s (ideal 15–25). It is frozen as the default of `start.sh`,
`serve.sh`, `qwen.sh`, `llamactl.sh` and therefore of `sudo service llama start`.

This is the consolidated report. The chronological working log with every number, log excerpt and dead end is
`results-t1.md`; the plan and shortlist are `plan.md`; how the box is operated is `ops.md`. All three are in this directory.

## 1. What T-1 means and what was required

`plan.md` §10 (owner, 12 Sep 11:14–11:24) defines three serving profiles, each = the tier's best model *by the E2E coding
tasks* in its best configuration *by the sweeps*:

| profile | tier | placement | generation-speed goal (output t/s, session aggregate) |
|---|---|---|---|
| **`fastest-vram`** | **T-1** | everything in the 16 GiB Quadro: weights, 262 144-token q8_0 KV, compute buffers | **> 12, never < 10, ideal 15–25** |
| `fast` | T0 | VRAM first, overflow to the Intel iGPU (Vulkan1) or CPU RAM — whichever measures faster | ≥ 6, minimum 4, ideal 7–10 |
| `best` | T1 (T2 optional) | as much as fits across VRAM + iGPU + RAM, whichever split is fastest | ≥ 1.8, minimum 1, ideal > 3 |

Hard requirements applied to every T-1 candidate: the **full native context (262 144 tokens per slot)**, thinking on
(effort max where the template has such a knob), GPU-only (`--gpu-layers 99 --device Vulkan0 --fit off`), q8_0 K and V,
flash attention, no YaRN, `--parallel` as high as fits (4 → 3 → 2 → 1), the model card's sampling. Speed is *recorded* for
prompts too, but only output speed is a selection criterion, and it must hold **at depth** (a model must clear the floor
at 200K context, not only on a fresh one).

Verdict vocabulary (owner, 11:52), used in every table below: **PASS**; **FAIL-task** = the run completed normally (qwen-code
exited by itself or hit the 4-h cap, server healthy throughout) but the program does not meet the spec — a *model*
result; **FAIL-infra** = something of ours broke (llama-server crash/stall, qwen-code error, thermal action, freeze,
network) — never counted against a model, the task is re-run.

## 2. The box and the test conditions

Dell Precision 7750: Xeon W-10885M (8C/16T, Comet Lake, AVX2), **Quadro RTX 5000 16 GiB** (nvidia 595.99.02, Vulkan 1.4,
`NV_coopmat2`), Intel UHD P630 iGPU (Mesa ANV; X runs on it; Vulkan heap 95.7 GiB UMA), 128 GiB DDR4, 4 × KC3000 NVMe, FreeBSD
15.1-STABLE, GELI. llama.cpp = the POC fork v0.4.0 `5266f24`, native Vulkan build; from 12 Sep 14:40 the patched
`build-vulkan-2` (see §7.3). Model files on the `zroot/data/local-ai` dataset (`primarycache=all` since 11 Sep 21:2x, so a
restart reloads 11 GB from ARC in ~10 s; **reverted to `metadata` + a 16 GiB ARC cap on 13 Sep 01:05** — an unlimited ARC
starved the NVIDIA pinned host buffers that T0 needs, results-t0.md §3.2).

Thermal regime during all tests (unchanged since the owner's 11 Sep 21:26 decision): `thermal_policy` "turbo band" — the
CPU cap follows the hottest core between 5.3 GHz (≤ 70 °C) and 2.4 GHz (≥ 85 °C), no turbo while PCH ≥ 85 °C or NVMe
≥ 70 °C, EPP 100; BIOS Thermal Management "Cool"; the Dell EC forces an NVIDIA `SW Thermal Slowdown` from 67–70 °C GPU
(SM clock 1 800–1 935 → 1 065–1 700 MHz), which is why sustained decode is ~10–15 % below the first-seconds burst on every
model. `telemetry.sh` (5-s CSV + a guard that stops the server at PCH ≥ 102 °C) ran under every test; it never fired.
Every speed figure in this report was measured under that regime — no thermal setting was ever relaxed for a test.

## 3. Method

1. **Download** (`download.sh MODEL`, one at a time, `curl -C -`, sha256 against the HF LFS oid; ~12 MB/s on 5 GHz Wi-Fi).
2. **Fit ladder**: `start.sh MODEL` with NP = 4, 3, 2, 1 at ctx = NP × 262 144 until the server comes up; record VRAM
   (`nvidia-smi`), start time, and where it failed (always the KV allocation).
3. **Spec-decoding sweep** (`sweep.sh MODEL "label=SPEC" …`, 150 s idle gaps so every config starts at the same GPU
   temperature, `codebench.py`: two realistic coding prompts, thinking on, greedy, 2 048-token cap): `ngram-mod`,
   `none`, and `draft-mtp` where the file has an MTP head. Winner = highest aggregate tg.
4. **The four-task E2E** (`e2e-all.sh MODEL` → `e2e-test.sh` per task): each task is one headless qwen-code session
   (`qwen.sh --yolo`, `contextWindowSize` 262 144, `autoCompactThreshold` 0.95, **4-h cap**) against the running server;
   the model must create the project, build, test and fix it itself. An **independent verifier** (`verify-*.sh`, never
   shown to the model) then builds the source and checks behaviour against a Python/coreutils reference — its
   `VERDICT:` line is the strict pass/fail. A stall detector (`unstick.sh watch 30`) replaces a hung server (never needed
   after the fix in §7.3). Everything is kept in `/data/ai/<task>-task-<model>/` (`summary.txt` with server-side timings
   and a per-request table, `qwen.log`, `verify.txt`, the project).

| # | task | toolchain | the program | what usually breaks |
|---|---|---|---|---|
| 1 | **rust** (easy) | Rust, `cargo` | `revstr`: reverse stdin by Unicode scalar values, strip exactly one trailing newline, unit tests incl. Polish and emoji | reading stdin line by line, stray characters |
| 2 | **go** (medium) | Go 1.27 stdlib | `wordfreq`: top-N words, `IsLetter||IsDigit` runs folded with `ToLower`, count desc then word asc, `-n`, exit codes; 47 checks incl. a **6 MB single-line input** | `bufio.Scanner`'s 64 KB line limit |
| 3 | **c** (hard) | C11, `cc -Werror`, bmake + gmake, ASan | `bignum`: signed arbitrary-precision `+ - *` on decimal strings up to 10 000 digits, canonical output, `error` for malformed lines, `--selftest`; 420 arithmetic vectors + malformed-input check | sign handling, buffers, faking `--selftest` |
| 4 | **asm** (hardest, long context) | x86-64 GNU as + `ld`, **no libc**, FreeBSD syscalls | `b64`: streaming base64 encoder / `-d` decoder over stdin/stdout, short read/write handling, 700 vectors each way | Linux syscall numbers, never assembling, SIGSEGV loops |

All four verifiers were validated against my own reference implementations before any model ran.

## 4. Candidates

Shortlist from `plan.md` §4 (two wide model sweeps, ~20 labs, sizes re-fetched from HF 11 Sep). The T-1 constraint —
weights + 256K q8_0 KV + compute ≤ 16 GiB — leaves only small MoEs and ≤ 9B dense models at ≤ 11–12 GiB of weights:

| name | model | file (GiB) | why |
|---|---|---|---|
| `north` | Cohere **North-Mini-Code-1.0** (30B-A3B coder, interleaved thinking, 500K native, tied embeddings) | UD-IQ3_XXS 10.9 | the coding-specialised pick, fastest on paper |
| `qwen9b` | **Qwen3.5-9B** dense (hybrid Gated-DeltaNet) with **MTP head** | Q8_0 9.1 | the no-quant-risk reference; the only dense candidate; MTP |
| `gemma` | **Gemma-4-26B-A4B-it** (generalist, LCB 77 / SWE-V 57) | UD-IQ3_S 10.6 | the alternative if North's 3-bit quality disappoints |
| `qwen35b` | **Qwen3.6-35B-A3B** (SWE-V 73 / LCB 80 class), non-MTP file | UD-IQ2_M 10.7 | "test-only": a 35B-A3B entirely in VRAM with 2-bit experts — quality unknown |

Rejected for T-1 with reasons in `plan.md` §4: Qwen3.6/3.8-27B dense (KV 8.5 GiB at 262K on top of 16.4 GiB weights),
gpt-oss-20b (128K), Nemotron-3.5-Lightning / Cascade-2 (no i-quant file fits: `moe_intermediate 1856`), Qwen3-Coder
(non-thinking), everything ≥ 122B (T1/T2 material).

## 5. Results per model

### 5.1 North-Mini-Code-1.0 UD-IQ3_XXS

- **Fit**: NP 4/3/2 fail at the KV allocation (`failed to allocate Vulkan0 buffer of size 570425344`); **NP=1 up in 20–24 s,
  15 623 / 16 384 MiB (95 %)** — exactly the plan's 15.7 GiB. NP=2 GPU-only is impossible for any quant of this model (a
  second 256K KV slot is +3.6 GiB).
- **What limits its speed** (the calibration model for the whole tier): the decode loop is bound by the CPU-side graph
  launch path (49 layers × ~35 Vulkan dispatches per token) — at EPP 100 the driving core idles at ~900 MHz (30 t/s), at
  2.4 GHz 40 t/s; thread count is irrelevant; sampling is free (the 262 144-token vocabulary sort is not measurable);
  after 30–60 s the EC's GPU slowdown makes the GPU the bottleneck (35–39 t/s sustained). Prompt processing ≈ 1 300 t/s at
  2K, 1 050–1 190 t/s at 16K, 591 t/s on a 64K cold batch, 230–310 t/s on 1–4K batches at 80–130K depth.
- **Sweep**: `ngram-mod` (n6) best; n12 worse (deeper drafts rejected more).
- **E2E** (`SPEC=ngram-mod`, 22:54–00:22, 1 h 28 min):

| task | wall | turns | tg t/s agg (min–max) | ctx max | verdict |
|---|---|---|---|---|---|
| rust | 156 s | 11 | 23.0 (19.6–25.5) | 26.9K | **FAIL-task**: `print!("{} \n", …)` — a stray space before the newline; everything else right |
| go | 964 s | 75 | 26.3 (12.1–53.6) | 56.8K | **FAIL-task 46/47**: correct program, but `bufio.Scanner` → the 6 MB line dies with "token too long" |
| c | 2 336 s | 85 | 32.0 (11.7–56.1) | 101.4K | **FAIL-task**: after a real 8.8 KB attempt it *regressed to a 130-line stub* whose `--selftest` prints "selftest ok" with zero asserts; only `1 + 1` works |
| asm | 1 799 s | 63 | 25.5 (9.5–47.9) | 132.8K | **FAIL-task**: 37-line stub with **Linux** syscall numbers (0/1/231 instead of FreeBSD 3/4/1) → SIGSEGV on every input; never opened `sys/syscall.h` although the prompt pointed there |

North = **0 / 4**. A competent small-task coder (both easy tasks one typo away) that collapses on the harder two and
then fakes the acceptance criteria. Speculation lesson from its logs: `ngram-mod` reaches 90–95 % acceptance when the
model re-emits a whole file with small edits (45–54 t/s), 0–10 % on short tool-call turns (13–22 t/s).

### 5.2 Qwen3.5-9B Q8_0 + MTP

- **Fit**: NP=1 only; **up in 8 s, 15 337 MiB** with the MTP draft (the draft costs 2.1 GiB: its own 262K KV + compute).
- **Sweep** (00:33–00:54): `draft-mtp,ngram-mod` best — the MTP head is worth ≈ 1.8–2× on this dense model, n-gram adds
  another 5–15 %; acceptance in agentic mode 62–64 % from the first turn.
- **E2E** (`SPEC=draft-mtp,ngram-mod`, 00:56–13:48 with interruptions):

| task | wall | turns | tg t/s agg (min–max) | ctx max | verdict |
|---|---|---|---|---|---|
| rust | 136 s | 9 | 26.8 (17.1–52.5) | 27.3K | **FAIL-task 14/18**: `reverse()` right, but `main()` prints after *every* stdin line instead of reading all of stdin once |
| go | 575 s | 27 | 21.1 (13.9–34.0) | 39.0K | **PASS 47/47**: `bufio.Reader`, 147-line `main.go` + 242-line table-driven tests, `-n` and tie-break exact |
| c | **331 min** (91 min fresh run that claimed done + 240 min resume to the 4-h cap; a first 59-min attempt was lost to the 02:09 freeze = FAIL-infra, re-run) | 698 msgs | 17.8 (fresh 29.7, resume **14.3**; **6.9 at 200K**) | 229.1K | **FAIL-task**: 5.5 h of persistent, honest debugging (317 tool calls, one 201K-token compaction) that never converged: UB in the parser, leftover debug prints, wrong results |
| asm | 87 min net (121 min wall; 2 071 s of server downtime excluded) | 130 | 15.7 (8.9–42.2) | 179.8K | **FAIL-task**: an incoherent 160-line encoder that segfaults, then a repetition loop that qwen-code halted. The two llama-server SIGABRTs at 12:21 and 12:43 during this task are **FAIL-infra** (§7.3), excluded from the timing |

qwen9b = **1 / 4**. It does not fake anything (the C session is the proof: hours of real build-test-fix), but it is too
weak for the hard tasks, and it is the only candidate whose speed **misses the T-1 floor at depth**: 8.5–10 t/s at 100K,
6.9 t/s at 200K, although the session aggregates (15.7–26.8) pass. It also needs the MTP head to be competitive at all.

### 5.3 Gemma-4-26B-A4B-it UD-IQ3_S

- **Fit**: NP 4/3/2 fail (same 570 MiB KV allocation); **NP=1 up in 11 s, 14 545 MiB**.
- **Sweep** (14:59–15:07): `ngram-mod` 48.5 / 40.6 t/s vs `none` 48.3 / 43.8 — a wash (aggregate 42.7 vs 44.9); the E2E
  ran with the models.sh default `ngram-mod` for parity with North/qwen9b.
- **E2E** (15:08–16:33, 1 h 25 min):

| task | wall | turns | tg t/s agg | ctx max | verdict |
|---|---|---|---|---|---|
| rust | 274 s | 12 | 37.1 (25.5–58.9) | 31.8K | **PASS 18/18**: 48-line `main.rs`, 4 unit tests, `chars().rev()` |
| go | 161 s | 10 | 55.8 (30.7–85.9) | 28.8K | **FAIL-task 46/47**: `bufio.Scanner` again — identical to North's failure |
| c | 2 142 s | 20 | 36.8 (19.7–57.7) | 80.2K | **FAIL-task**: 329-line `bignum.c` builds clean but every expression double-frees → 0/420; the selftest asserts fail; qwen-code's loop detector stopped it (identical tool calls) |
| asm | 2 353 s | 24 | 30.3 (25.2–36.0) | 141.8K | **FAIL-task**: a 297-line `b64.s` that **was never assembled** — **23 `write_file` calls and 0 shell commands** in the whole session (`(%rsi+1)` syntax, `add` type mismatches); the prompt explicitly demands running `make` until the tests pass |

gemma = **1 / 4**. The fastest raw decoder of the four (30–56 t/s), but it writes code blind: it does not run what it
writes, so it cannot debug. (Note for later tiers: KAT's model card reports the same two failure modes for Gemma-4-26B in
their harness — context overflow and hallucinated tool calls.)

### 5.4 Qwen3.6-35B-A3B UD-IQ2_M — the winner

- **Fit**: NP=2 fails (`131727360`-byte buffer); **NP=1 up in 17 s, 14 099 MiB** — the whole 35B-A3B in VRAM, 2.3 GiB
  headroom, `--cache-ram 8192` affordable (context checkpoints in RAM).
- **Sweep** (16:38–16:50): **`none` 61.3 / 56.4 t/s (aggregate 58.7)** vs `ngram-mod` 50.3 / 50.3 (50.3) — speculation
  *costs* 17 % on this MoE (each verified draft token loads its own experts; ~50 % acceptance) → E2E with `SPEC=none`.
- **E2E** (`SPEC=none`, 16:51–21:43, 4 h 52 min incl. the 4-h asm cap):

| task | wall | turns / shell cmds | tg t/s agg (min–max) | pp t/s agg | ctx max | verdict |
|---|---|---|---|---|---|---|
| rust | **110 s** | 14 / 5 | 45.8 (38.9–47.7) | 800 (cold 22.9K batch) | 28.6K | **PASS 18/18** |
| go | **256 s** | 20 / 13 | 44.0 (39.3–48.7) | 963 (cold batch) | 37.3K | **PASS 47/47** — incl. the 6 MB line; 527 lines with 5 test functions |
| c | 2 584 s | 117 / 57 | 34.8 (26.6–44.8) | 383 agg (967 cold) | 135.3K | **FAIL-task, near-miss**: 488-line `bignum.c`, `-Werror` + ASan clean, selftest ok, **420/420 arithmetic exact**; the only defect: blank input lines are echoed as empty lines instead of skipped |
| asm | 4-h cap (rc=124) | 253 requests / 212 | 30.4 (18.1–43.0) | 214 agg (438 cold 82K) | **234.6K** (two qwen-code compactions) | **FAIL-task**: final 497-line `b64.s` assembles and links, encode still SIGSEGVs, `-d` rejected; 11 rewrites, `ktrace` used; after each compaction a 25K-token re-think |

qwen35b = **2 / 4 + near-miss**. It is the one candidate that *behaves* like a coding agent: it runs what it writes every
time, keeps a build–test–fix loop going for hours without repeating itself, and its 2-bit experts cost nothing visible on
rust/go. Where it fell short (C blank lines, asm) the failures are reasoning failures, not quantisation artefacts we could
point at. Prompt processing is the price of a 128-expert MoE on Vulkan: 214–666 t/s aggregate, an 82K cold re-encode
≈ 3 min. Infra: 5 h 20 min of continuous serving on the patched build, contexts to 234.6K, 343 619 prompt / 382 591
generated tokens in the asm session alone, zero restarts, zero FAIL-infra.

## 6. Scoreboard and decision

| | North IQ3_XXS | Qwen3.5-9B Q8_0+MTP | Gemma-4-26B IQ3_S | **Qwen3.6-35B IQ2_M** |
|---|---|---|---|---|
| rust (easy) | FAIL (stray space) | FAIL 14/18 | **PASS** 4.6 min | **PASS 1.8 min** |
| go (medium) | FAIL 46/47 | **PASS** 9.6 min | FAIL 46/47 | **PASS 4.3 min** |
| c (hard) | FAIL (stub) | FAIL (5.5 h) | FAIL (0/420) | FAIL **near-miss** (420/420 arithmetic) |
| asm (hard, long ctx) | FAIL (Linux syscalls) | FAIL (SIGSEGV, loop) | FAIL (never assembled) | FAIL (SIGSEGV at the 4-h cap) |
| **score** | **0 / 4** | **1 / 4** | **1 / 4** | **2 / 4 + near-miss** |
| runs its own builds/tests | sometimes | yes | **no** (0 shell calls on asm) | **always** |
| tg t/s, session aggregate (worst request) | 23.0–32.0 (9.5) | 15.7–26.8 (**6.9 @ 200K**) | 30.3–55.8 (19.7) | 34.8–45.8 (18.1 @ 230K) |
| pp t/s aggregate | 591–1 067 | 256–795 | 233–599 | 214–666 |
| deepest context reached | 132.8K | 229.1K | 141.8K | 234.6K |
| VRAM at NP=1 (MiB / 16 384) | 15 623 | 15 337 | 14 545 | **14 099** |
| T-1 speed goal (> 12, never < 10, ideal 15–25) | met | aggregate met, **floor missed at depth** | exceeded | **exceeded at every depth** |
| spec decoding | `ngram-mod` (+, 17–63 % acc.) | `draft-mtp,ngram-mod` (×1.8–2) | neutral | **`none`** (n-gram −17 %) |

**Decision: `qwen35b`.** Same score as nobody, one point ahead of gemma/qwen9b, the only real agentic behaviour, the best
fit (2.3 GiB headroom, so `--cache-ram 8192` is affordable), and speed well inside the goal at 230K context. gemma is the
faster decoder but blind; qwen9b is honest but weak and too slow at depth; North last.

Facts that shape the next tiers: **no T-1 model fits NP=2** at 262K per slot (the second KV never fits — a single slot
is a property of the tier, not of a model); speculation helps dense models and hurts this MoE family; the CPU's clock
matters for GPU-only decode (graph launch path) — the turbo band handles it.

## 7. Infrastructure events, root causes and fixes (all FAIL-infra, none counted against a model)

### 7.1 Thermal power-off, 11 Sep 21:05
During the first North sweep with a download in parallel the **PCH** (Intel 400-series, `dev.pchtherm.0`) rose to
110 °C — driven by the four NVMe drives on its lanes during `sha256`/model reads, not by the CPU (5–7 W) or GPU
(64–69 °C) — and *our* watchdog executed its configured `shutdown -p`. Consequences: `WD_PCH_CRIT` 110 → 115 (owner; the
PCH self-throttles at 108/111/114, hardware trip 120), model dataset `primarycache=all` (restarts read from ARC, zero NVMe
traffic), sha256 never during a speed test, `telemetry.sh` + guard under every test, and the 21:26 "turbo band" regime.
Also learned: **`/var/tmp` is a 1 GiB tmpfs wiped at boot** — all state moved to `~/local-ai-runs/`.

### 7.2 Hard freeze, 12 Sep 02:09
Not thermal (last telemetry row: PCH 71, core 67, GPU 73 °C, no watchdog event); the box was power-cycled by the owner at
05:55. The qwen9b C task in flight (59 min) was re-run. Follow-ups the owner asked for: the watchdog's critical action is
now **suspend (`zzz`)** instead of power-off, and a live S3 test (07:26, 93 s) showed **the server survives the suspend but
its in-flight GPU work does not** → `unstick.sh pre-suspend/post-resume` hooks and the E2E stall detector handle it (`ops.md`
§4).

### 7.3 llama-server SIGABRT ×2, 12 Sep 12:21 and 12:43 — root-caused and fixed
`ggml_vulkan: Memory allocation of size 269924352 failed` in `create_checkpoint → state_seq_get_data` during the qwen9b
asm task at ≈ 130K context. Root cause, proven with stand-alone Vulkan probes: **the NVIDIA FreeBSD driver fails single
host-visible (pinned) allocations ≥ 256 MiB** — all of them without `VK_EXT_memory_priority`; with it (ggml's case) the sizes
in the windows [256, 265), [512, 522), [1024, 1035), [2048, ≈2062) MiB, and the outcome inside a window depends on the
process' pinned-allocation history (not a fixed cap, no runtime knob). ggml sizes its synchronous staging buffer to the
largest single transfer, and a context checkpoint of a ≥ 128K-token f16 draft KV (2 048 B/token) needs one such read.
**Fix**: `patches/0001-vulkan-chunk-staging-transfers.patch` — staging transfers in ≤ 64 MiB pieces
(`GGML_VK_STAGING_CHUNK_MB`, `GGML_VK_STAGING_LOG=1`), built as `build-vulkan-2` (`build-vulkan-2.sh`), validated with
`verify-staging.sh` (136K-token prompt + checkpoints, f16 and q8_0 draft KV: staging capped at exactly 67 108 864 B, no
crash), `serve.sh` default since 14:40. Since then: gemma + qwen35b, 6 h 50 min of serving, contexts to 234.6K, **zero
FAIL-infra**. The 544 MiB "Failed to allocate pinned memory" warning at model load is the same driver behaviour and is
harmless.

## 8. The frozen configuration

| item | value |
|---|---|
| `models.sh` `qwen35b` | `Qwen3.6-35B-A3B-UD-IQ2_M.gguf` @ `a483e9e` (sha256 verified), `MODEL_SPEC=none`, `MODEL_CACHE_RAM=8192`, `MODEL_NCMOE=0`, `enable_thinking: true`, temp 1.0 / top-p 0.95 / top-k 20 / min-p 0 |
| `serve.sh` | `B=` = `build-vulkan-2/bin/llama-server`; `--ctx-size 262144 --parallel 1 --gpu-layers 99 --device Vulkan0 --fit off --flash-attn on --cache-type-k/v q8_0 --cache-ram 8192 -b 2048 -ub 1024 --ctx-checkpoints 8 --spec-type none --jinja --reasoning on --reasoning-budget -1`, binds `10.253.254.1:18080` |
| defaults | `start.sh` / `serve.sh` / `qwen.sh` / `llamactl.sh DEFAULT_MODEL` = `qwen35b` → `sudo service llama start` (or `./start.sh`) brings up the T-1 profile; verified 21:46: UP in 5 s, 14 099 MiB, `--spec-type none`, then `./stop.sh` |
| freeze (13 Sep 00:30) | only `qwen35b` kept — North / Qwen3.5-9B / Gemma-4 GGUFs deleted (32.8 GB freed), their `models.sh` entries removed (git history), defaults in `serve.sh`/`qwen.sh`/`llamactl.sh`/`e2e-*.sh`/`download.sh` all point at `qwen35b`; run artifacts kept (`sweep-*.csv`, `e2e-*.log`, `/data/ai/*-task-{north,qwen9b,gemma}/`) |
| use | `sudo service llama start [MODEL]` / `stop` / `status`; `asgard/qwen.sh [--yolo] …` (qwen-code preconfigured with the model's sampling); `asgard/health.sh`; per-model overrides via environment: `NP CTX THREADS NCMOE IGPU_MOE SPEC EXTRA` |

## 9. Open items and what T0 starts from

- T0 candidates queued for download 12 Sep 21:52 (`models.sh`: `qwen35b-q4` = UD-Q4_K_XL 20.8 GiB, `kat-q4` = KAT-Coder-V2.5-Dev
  Q4_K_L 20.3 GiB, `qwen35b-q8` = Q8_0 34.4 GiB). Each needs a fit ladder (how many expert layers must leave VRAM), the
  **iGPU-vs-RAM placement sweep** (`IGPU_MOE=k` vs `NCMOE=k`; serve.sh has both, per-model defaults `MODEL_IGPU_MOE` /
  `MODEL_NCMOE`), the spec sweep, then the same four-task E2E. Results go to `results-t0.md`.
- Untested: whether gemma's `--cache-ram 0` could be lifted now that staging is chunked; the exact driver mechanism behind
  the 2^n allocation windows; North at its 500K native context (needs ~18 expert layers off the GPU).
- Everything under `/data/local-ai` is uncommitted since "Update status 6" — `git add -A && git commit` when convenient
  (the llama.cpp working tree at `/data/ai/local-agent-poc/src/llama.cpp` carries the staging patch uncommitted too; the
  patch file in `patches/` is the source of truth).

## 10. Artifact index

- Docs: `results-t1.md` (full log; §5 = verdict), `plan.md` (§4 shortlist, §10 profiles/goals), `ops.md` (§6 verification log),
  `status-2026-09-11.md`, `asgard-thermal-report-20260911.md` (thermal, in `asgard-cfg` on tuxi).
- Scripts: `models.sh serve.sh start.sh stop.sh llamactl.sh rc.d/ qwen.sh health.sh download.sh sweep.sh codebench.py bench.py
  e2e-all.sh e2e-test.sh e2e-tasks.sh e2e-vectors.py verify-{rust,go,c,asm}.sh unstick.sh telemetry.sh verify-staging.sh
  build-vulkan-2.sh patches/`.
- Raw results on asgard: `~/local-ai-runs/sweep-{north,qwen9b,gemma,qwen35b}.csv`, `e2e-*.log`, `vt/staging-*.out` (fix
  validation), `/data/ai/{rust,go,c,asm}-task-{north,qwen9b,gemma,qwen35b}/` (`summary.txt`, `qwen.log`, `verify.txt`, project).
