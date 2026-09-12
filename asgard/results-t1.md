# asgard T-1 results — download, fit, speed, coding test (2026-09-11)

Companion to `asgard/plan.md` (§4 shortlist, §5 configs, §6 pinned-cap rules, §7 protocol) and
`asgard/status-2026-09-11.md`. Everything here was measured on asgard as configured **today**:
Xeon W-10885M with **Turbo disabled in UEFI (2.4 GHz cap)**, `thermal_policy` applied (EPP 100
default; EPP 0 set at runtime for the tests and restored after), BIOS Thermal Management "Cool",
Quadro RTX 5000 16 GiB on nvidia 595.99.02 via Vulkan (NV_coopmat2), X on the iGPU, llama.cpp POC
fork v0.4.0 `5266f24` `build-vulkan`. Hard requirements applied to every model: full native context
(262 144), thinking on, effort max where the template has such a knob, GPU-only (`--gpu-layers 99
--device Vulkan0`), no YaRN, `--parallel` as high as fits (4 → 3 → 2 → 1).

Scripts: `asgard/download.sh MODEL` (sha256-verified into `models/` on the dataset),
`asgard/start.sh MODEL` / `asgard/stop.sh` (daemonized `asgard/serve.sh`), `asgard/health.sh`,
`asgard/bench.py` (pp/tg vs depth, `/completion`), `asgard/codebench.py` (real coding prompts via
`/v1/chat/completions`, thinking on), `asgard/rust-test.sh MODEL` (the full test: `asgard/qwen.sh`
headless writes+builds+tests a Rust string reverser, verified independently; output preserved in
`/data/ai/rust-task-MODEL/`).

## 0. Thermal incident 21:05 and the test conditions that follow from it

**What happened.** During the first North speculative sweep (server restarted per config, qwen9b
downloading in parallel) the thermal watchdog logged `PCH 95 → 99 °C` and stepped the CPU cap
2400 → 1200 MHz (21:00–21:02), the PCH kept climbing (104 → 108 °C at 21:03–21:04 with the CPU
package at **5–7 W** and the GPU at 64–69 °C) and at **21:05:01** it executed its configured
action: `CRITICAL: PCH 110 C >= 110 C — shutdown -p now`. Clean software poweroff by *our*
watchdog (`WD_PCH_CRIT=110`), not BIOS/EC. Owner re-enabled Turbo in UEFI and set Thermal
Management Cool → Optimized, booted (GELI), and asked that thermal settings stay as they are.

**Where the heat comes from.** `dev.pchtherm.0.temperature` (Intel 400-series PCH Thermal
Subsystem 8086:06f9, formula raw/2 − 50 as in Linux `intel_pch_thermal`) is a real, dynamic
sensor: 65–68 °C idle all evening; 87–103 °C whenever the **NVMe drives are busy** (rsync at
16:28/17:03, model loads, sha256 verify — the `sha256 -q` of the 9 GB qwen9b file alone, with no
server running, held it at 97–102 °C); it falls ~35 °C within 6 min once I/O stops. A single
sequential read of the 11 GB North file (24 s) lifted it 75 → 90 °C. The four KC3000 sit on the
PCH's PCIe lanes next to the PCH; nvme3 is always the hottest (67–73 °C). GPU load alone was never
measured cleanly before the incident — sweep v2 below does that. The watchdog's only lever
(capping the CPU) cannot cool an NVMe/PCH-driven rise.

**Who would stop the machine without the watchdog** (all read from the box):
PCH self-throttles its links at T0/T1/T2 = **108/111/114 °C**, hardware catastrophic trip
**CTT 120 °C** (instant power cut, no OS); CPU Tjmax 100 °C, PROCHOT at 90 °C (TCC offset 10),
THERMTRIP ≈ 125–130 °C; GPU slowdown 97 °C / shutdown 102 °C (Dell EC additionally forces "SW
thermal slowdown" from 67–70 °C); NVMe HCTM 70/77 °C, WCTEMP 84 / CCTEMP 89 °C (throttle only);
ACPI `tz0._CRT` 107 °C but tz0 reads a constant 25.1 °C. So the 110 °C rule fires 2 °C above the
PCH's first throttle point and 10 °C under the hardware trip. Owner's decision 21:17: **`WD_PCH_CRIT`
110 → 115** (soft poweroff still preferred over the 120 °C hardware cut; the reading is suspected
pessimistic) — applied to `/usr/local/etc/thermal-policy.conf`, watchdog restarted, backups in
`asgard-cfg/thermal/` on tuxi+asgard updated, addendum in `asgard-thermal-report-20260911.md`.
Also checked: UEFI Turbo is now *permitted* (HWP caps highest ratio 53) but the policy's
`TURBO_DISABLE=yes` MSR bit keeps it off (2.4 GHz ceiling), and Cool → Optimized changed nothing
observable — the EC still throttles the GPU from 68 °C (`SW Thermal Slowdown`, SM ≈ 1.6–1.7 GHz).

**Consequences for testing (no thermal setting changed):**
1. `zfs set primarycache=all zroot/data/local-ai` (was `metadata`): model files stay in ARC
   (128 GiB RAM), so server restarts read from RAM (10 s for 11 GB, zero NVMe traffic) instead
   of re-reading the drives every time. Prefetch once per model: `cat model.gguf > /dev/null`.
2. `asgard/telemetry.sh` runs under daemon(8) during every test: 5 s CSV of PCH / max core /
   CPU MHz / watchdog cap / GPU temp-clock-power-util-throttle-reason, and a **guard** that runs
   `stop.sh` at PCH ≥ 102 °C (event in `~/local-ai-runs/guard.log`). It observes only.
   **`/var/tmp` on asgard is a symlink to `/tmp` = 1 GiB tmpfs, wiped at every boot** — found the hard way at the
   21:44 reboot (all earlier sweep CSVs, llama logs, the Vulkan build log and `suspend-test/` are gone; every
   number quoted here was already transcribed). All asgard scripts now write to `~/local-ai-runs/`
   (`LOCAL_AI_RUNS` override): `llama.log`, `llama.pid`, `telemetry.csv`, `guard.log`, `qwen-home/`, sweep
   scripts/CSVs, download logs.
3. Sweeps pause 60 s between server starts; downloads (12 MB/s writes, PCH ≤ 76 °C on their
   own) keep running in the background.
4. All speeds are reported **with the watchdog cap that was in force**. Regime change 21:26
   (owner): Turbo allowed via a "turbo band" — the cap follows the hottest core between 5.3 GHz
   (≤ 70 °C) and 2.4 GHz (≥ 85 °C), no turbo while PCH ≥ 85 °C or NVMe ≥ 70 °C, and the old
   stepping 2.4 → 1.2 GHz when HOT (core ≥ 85, PCH ≥ 95, NVMe ≥ 75). EPP stays 100 (policy
   re-applies it every 10 min), so a lightly loaded decode thread still idles at ~900 MHz — the
   EPP 0 numbers below are one-off probes, not a config. Sweep rows carry `cap=` and `pch=`.

Old-regime sweep fragments (kept for reference, 2.4 GHz ceiling, EPP 100; `codebench` 2 prompts ×
2048 tok, greedy): ngram-mod n6 **26.0 t/s** agg at cap 1600→2200 MHz (start pch 80); n12
22.1 t/s at cap 2400 (its 2nd prompt 19.6 t/s — deeper drafts are rejected more); n3 interrupted.

## Downloads (one at a time, `curl -C -`, ~12 MB/s on 5 GHz Wi-Fi)

| model | file | bytes | sha256 (HF lfs.oid) | time | status |
|---|---|---|---|---|---|
| north | North-Mini-Code-1.0-UD-IQ3_XXS.gguf @ e306bb4 | 11 708 375 136 | 029b51f9…7140 | 15:25 | verified 20:28 |
| qwen9b | Qwen3.5-9B-Q8_0.gguf @ 9716a63 (MTP repo) | 9 786 061 152 | 107125cd…ad4e | 20:47–21:02 | verified 21:13 (first verify interrupted by the 21:05 power-off) |
| gemma | gemma-4-26B-A4B-it-UD-IQ3_S.gguf @ c099eb4 | 11 289 671 136 | 878be93f…3e29 | 21:13–21:29 | verified 21:35 |
| qwen35b | Qwen3.6-35B-A3B-UD-IQ2_M.gguf @ a483e9e | 11 522 702 304 | 2be7ef1e…3d43 | 21:35–21:58 (2 reboots, `curl -C -` resumed twice) | verified 22:35 |

`sha256 -q` is single-threaded: 52 MB/s at the 1.1 GHz cap (3–4 min per file) vs 208 MB/s at turbo (56 s) — but at
turbo one core sits at 88 °C, which (shared heatsink) pushes the GPU into its 300 MHz throttle, so verification is
never run while a speed test is on.

## 1. North-Mini-Code-1.0 UD-IQ3_XXS (T-1)

GGUF: `cohere2moe`, 49 layers (1 dense + 48 MoE, 128 experts top-8), 32 heads / 4 KV heads × 128,
**`context_length = 500000`** in the metadata (Cohere's card and Unsloth's page say 256K, 64K max
output) → tested at 262 144; the 500K question is in the notes below. Chat template: `reasoning`
defaults to **true** (only `reasoning_effort == "none"` turns it off — there is no "max"), so thinking
is on with no template kwargs; template supports preserved reasoning.

### Fit (ctx = NP × 262 144, q8_0 KV, `--fit off`)

| NP | result | VRAM |
|---|---|---|
| 4 | weights load (16 s), then `failed to allocate Vulkan0 buffer of size 570425344` for the KV cache | — |
| 3 | same | — |
| 2 | same | — |
| **1** | **up in 20–24 s** | **15 623 / 16 384 MiB (95 %, 761 MiB headroom)** |

`--n-cpu-moe 0` was enough (plan predicted 15.7 GiB — matched). NP=2 GPU-only is impossible with any
quant of this model at 2 × 256K (KV alone is +3.6 GiB per slot); unified KV (`--kv-unified -np 2 -c
262144`, two slots sharing one 256K pool) is the only 2-slot option that stays GPU-only — not tested,
the requirement is 256K per slot.

### Speed — what limits it (measured, not assumed)

- **CPU clock matters even though everything is on the GPU**: at EPP 100 the cores sat at **897 MHz**
  during decode (tg 30 t/s); EPP 0 → 2 400 MHz gives **40 t/s**, GPU utilisation 50 → 70 %. The decode
  loop is bound by the CPU-side graph/launch path (49 layers × ~35 Vulkan dispatches per token).
  Thread count is irrelevant for this model (t = 1/2/4/8 all 40.2–40.8 t/s) — use `--threads 4`.
- **GPU thermal**: after ~30–60 s of continuous decode the driver reports `SW Thermal Slowdown:
  Active` at 67–70 °C (platform/EC-imposed; reported target 87 °C, slowdown 97 °C, `-gtt` unsupported)
  and the SM clock drops 1 800–1 935 → **1 065–1 260 MHz** with GPU utilisation at ~90 %: from there
  the GPU is the bottleneck. Sustained tg on long answers is therefore **35–39 t/s**, bursts 41–42.
  Power never exceeded 108 W (limit 110 W; `SW Power Cap` only in the first seconds). Thermal settings
  are deliberately left as they are (stable system first).
- **Sampling is free**: temp 1.0 / top-p 0.95 / top-k 0 (model card) = 38.2 t/s aggregate, greedy
  35.1, top-k 40 39.0 — the 262 144-token vocabulary sort is not measurable at these speeds.
- `bench.py` filler-text rows must be read with care: `ngram-mod` on repetitive filler drafts 6
  tokens per step that get rejected (tg 80 → 42 → 27 t/s at depths 256 / 2K / 16K), while with
  `--spec-type none` tg is flat (30.9 / 30.8 / 25.8 at EPP 100; ~40 / 40 / 34 at EPP 0). Prompt
  processing: **≈1 300 t/s at 2K, ≈1 050–1 190 t/s at 16K** (`-b 2048 -ub 1024`).

### Speed — realistic coding prompts, spec-decoding sweep (`codebench.py`, thinking on, greedy, 2 048 tok/answer)

Final regime (BIOS Cool + Turbo, turbo band, EPP 100, North in ARC, 150 s idle between configs so every
config starts at GPU 56–63 °C). Two prompts per config; prompt 0 runs on a cool GPU, prompt 1 starts
~75 s later with the GPU already at 70–72 °C — the drop between them is the Dell EC throttle, not the
config. `pp` = prompt tokens/s, `tg` = generated tokens/s (server-side timings). Sweep v3, 21:49–22:33.

| spec config | pp p0 | tg p0 (cold) | tg p1 (hot) | tg aggregate | note |
|---|---|---|---|---|---|
| **`ngram-mod` n=6 (default)** | 256 | **28.4** | 22.6 | **25.2** | winner |
| `ngram-mod --spec-draft-n-max 12` | 274 | 26.6 | 23.2 | 24.8 | |
| `ngram-mod --spec-draft-n-max 3` | 254 | 26.6 | 22.4 | 24.4 | |
| `ngram-simple` | 259 | 30.1 * | 23.5 | 24.7 | * p0 stopped at 575 tokens (different greedy path) — not comparable |
| `ngram-cache` | 254 | 17.0 | 14.3 | **15.3** | clearly harmful |
| `ngram-map-k4v` | 263 | 27.4 | 21.1 | 23.5 | |
| `none --poll 0 --prio 2` | 250 | 25.1 | 23.3 | 24.1 | |
| `none` | 247 | 24.6 | 21.1 | 22.7 | baseline |

- Speculation gives North **+11–15 %** on real code/reasoning output (`ngram-mod` n6 vs `none`), far less
  than the +50 % seen on filler text; draft depth 3/6/12 is within noise. Pick **`ngram-mod` (defaults)**.
- **The GPU thermal state is a bigger effect than any config**: every prompt-1 number is 22–23 t/s
  regardless of speculation. Telemetry over the whole sweep (271 five-second samples with the server up):
  SM clock ≤ 500 MHz in **13 %**, 500–1 200 MHz in 32 %, > 1 200 MHz in 55 %; GPU max 75 °C; throttle
  reason `0x20` (SW thermal slowdown) dominant. In the earlier BIOS *Optimized* run the ≤ 500 MHz share
  was **36 %** and `ngram-mod` gave only 21.4 t/s — **Cool is the better BIOS thermal mode for this box**
  (the EC throttles the GPU less aggressively), which is why it was switched back.
- Prompt processing: ~250–275 t/s on these *short* prompts (150 tokens — dominated by per-request
  overhead); on 2K–16K prompts it is 1 050–1 300 t/s (§ above).
- Greedy decoding is not bit-reproducible across spec configs (batch size changes the Vulkan kernels
  → different argmax on near-ties): prompt 0 ended after 575 / 1 468 / 1 680 / 2 009 tokens for
  `ngram-simple` / `ngram-cache` / `map-k4v` / `none` and hit the 2 048 cap (still thinking) for the
  `ngram-mod` variants. North thinks for > 2 000 tokens on a 30-line coding prompt at temperature 0.
- Thread count, sampling and `--poll/--prio` are irrelevant at these speeds (see previous section).

### Full test — `asgard/rust-test.sh north` (22:35–22:38, `SPEC=ngram-mod`, NP=1, ctx 262 144)

qwen-code 0.23.0 headless (`--yolo`, thinking on, model's own sampling: temp 1.0 / top-p 0.95 / top-k 0)
against the running server; the task prompt asks for a cargo project `revstr` with
`pub fn reverse(s: &str) -> String` (by chars, not bytes), a `main()` that reads stdin, strips **one**
trailing newline and prints the reversed string, four unit tests (empty, hello, `Zażółć gęślą jaźń`,
emoji), no external crates, `cargo build --release` + `cargo test` until green, print the final source.

**Run**: 143 s wall, 10 agent turns, `result: success`, qwen rc 0. Tools used: `run_shell_command` × 5
(`cargo init`/`build`/`test`), `write_file` × 3, `edit` × 2, `read_file` × 3, `glob` × 1; two recoverable
tool errors (first `read_file` on a directory, one `edit` on a not-yet-existing file). qwen-code usage:
229 552 input tokens (206 293 served from cache), **2 055 output tokens**. Output preserved in
`/data/ai/rust-task-north/` (`Cargo.toml`, `src/main.rs`, `qwen.log`, `summary.txt`, `verify.txt`,
`timings.txt`, `per-request.txt`). North put the project in the work dir itself instead of a `revstr/`
subdir — accepted (the prompt says "in the current directory"); `rust-verify.sh` handles both layouts.

**Server-side speed** (llama log, 10 agent requests): the qwen-code system prompt + tool schemas are
**21 489 tokens**, processed once at **881 t/s** (24.4 s — the visible "startup" delay of every session);
the following turns hit the LCP cache (5–393 new prompt tokens, 107–457 t/s on those tiny batches).
Generation: 2 135 tokens in 104.5 s = **20.4 t/s aggregate** at 22–25K context depth, per request
13.8–25.0 t/s (short 60–120-token tool-call answers are the slow ones; the 627-token final answer ran
at 18.3 t/s with GPU at 72 °C and SM 800–1 300 MHz). `ngram-mod` acceptance over the run: **77 / 384 =
20 %** (0–2 % on the pure tool-call turns) — speculation buys almost nothing in agentic mode; it is
worth keeping only for the long code-emitting answers.

| step | tokens | t/s |
|---|---|---|
| first prompt (system + tools), cold cache | 21 489 in | 881 |
| later prompts (cache hit, delta only) | 65–393 in | 107–457 |
| generation, all turns | 2 135 out | 20.4 (13.8–25.0) |
| generation, ≥ 200-token answers | 1 573 out | 20.7 |

**Independent verification** (`rust-verify.sh`: fresh `cargo build --release`, `cargo test`, byte-exact
stdin round-trips vs Python `s[::-1]`, source checks):

- build ok; `cargo test` 4 passed / 0 failed; signature `pub fn reverse(s: &str) -> String` present;
  `s.chars().rev().collect()`; no deps, no `unsafe`; 45 lines.
- round-trips **17 / 18 ok** (re-verified 01:15 after a verifier fix — the original run reported 16/18 because
  the verifier's expectation for the input `abc\n` *without* an added newline was wrong; the model's `cba` was
  right): `hello`, Polish, emoji (`a🚀b👍`), empty, palindrome, padded spaces, combining marks (`e\u0301x\u0308`),
  multi-line — all correct, with and without trailing newline.
- **Spec deviation**: `input.trim_end_matches(|c| c == '\n' || c == '\r')` strips *all* trailing
  `\n`/`\r`, not exactly one (its own comment says "Strip one trailing newline") → `"abc\n\n"` gives
  `cba` instead of `\ncba`. Idiomatic fix is `strip_suffix('\n').unwrap_or(&input)`. Emoji test uses
  4 single-codepoint emoji (no ZWJ sequences) — fine for a chars-based spec.

**Verdict: correct reverse, working project, one edge-case deviation from the letter of the spec →
"PASS with 1 nit"** (`rust-verify.sh` itself says FAIL because it is strict). Quality-wise this is a
usable coding agent: it planned, created the project, wrote tests, ran build+test, printed the source,
in 2.4 minutes — of which 24 s was the one-off 21K-token prompt ingest.

### Full test, round 2 — the four-task E2E (`e2e-all.sh north`, 22:54–, `SPEC=ngram-mod`)

The E2E was widened to four tasks of rising difficulty (see the "E2E tasks" section at the end); each is a separate
qwen-code session with its own independent verifier; per-model output in `/data/ai/<task>-task-<model>/`.

| task | wall | turns | tool calls (errors) | prompt tok (cold batch) | generated tok | tg t/s agg (min–max) | ctx max | draft acc. | verdict |
|---|---|---|---|---|---|---|---|---|---|
| rust | 156 s | 11 | 14 (1) | 23 313 (21 489 @ 1 067 t/s) | 2 003 | 23.0 (19.6–25.5) | 26.9K | 16.6 % | **FAIL — stray space**: `print!("{} \n", …)` puts a space before the newline; everything else right (this run *did* strip exactly one newline). Its tests cover `reverse()` only, so `main()` was never exercised |
| go | 964 s | 75 | 75 (9) | 35 292 (21 640 @ 978 t/s) | 18 624 | 26.3 (12.1–53.6) | 56.8K | 43.1 % | **FAIL 46/47**: tokenizer, folding, ordering, `-n`, exit codes, tests all correct; reads stdin with `bufio.Scanner` → 64 KB line limit → the 6 MB single-line input dies with "token too long" |
| c | 2 336 s | 85 | 84 (11) | 38 165 (21 663 @ 933 t/s) | 66 095 | 32.0 (11.7–56.1) | 101.4K | 62.8 % | **FAIL**: after an 8.8 KB attempt that mis-handled signs it regressed to a 130-line stub — fixed 1001-byte buffers, `--selftest` just prints "selftest ok" (zero asserts), only `1 + 1` works; `0 - 0`, `5 - -5`, any `*` → `error`. Built warning-free and ASan-clean, though |
| asm | 1 799 s | 63 | 62 (21) | 82 686 (64 436 @ 591 t/s) | 32 049 | 25.5 (9.5–47.9) | 132.8K | 60.5 % | **FAIL**: 37-line stub that still uses the **Linux** syscall numbers (read 0 / write 1 / exit 231 instead of FreeBSD 3 / 4 / 1) → SIGSEGV on every input, 0/700 vectors either way; `make` broken; it never opened `/usr/include/sys/syscall.h` although the prompt pointed there; it also invoked a qwen-code `skill` ("new-app") and left `b64_simple.s`, `test.asm`, `README.md` behind |

**North verdict**: a competent *small-task* coder (both easy tasks were one typo away from passing, the Go
program is 306 well-structured lines with 4 table-driven tests) that **collapses on the two harder tasks** — in both
it produced a real attempt, could not debug it, and then *regressed to a stub that fakes the acceptance criteria*
(`--selftest` printing "selftest ok" with no asserts; a 37-line "b64"). Total E2E time 1 h 28 min for the four tasks.

Speed lessons from the agentic runs (all at 262K ctx, NP=1, GPU 68–74 °C):

- **Speculation pays in agentic mode after all**: when the model re-emits a whole file with small changes (`write_file`),
  `ngram-mod` drafts from the context and acceptance hits **90–95 %** → **45–54 t/s** (Go req. 20: 1 426 tok at 51.5 t/s,
  1 296/1 529 accepted). Short tool-call turns (60–120 tokens) run at 13–22 t/s with 0–10 % acceptance. Net: rust 16.6 %,
  go 43 %, c 63 % acceptance; aggregate 23 → 26 → 32 t/s as the sessions get more code-heavy.
- **Context depth costs**: at 25–45K depth short turns run 20–24 t/s; at 90–100K depth the same kind of turn runs
  13–15 t/s (C requests 46–82), 9.5 t/s minimum at 130K (asm). Prompt batches at depth: 21.5K system prompt at
  930–1 070 t/s (cold), the 64 436-token asm prompt at **591 t/s** (109 s), 1–4K batches at depth 80–130K only
  230–310 t/s.
- The 21.5K-token qwen-code system prompt + tool schemas is re-ingested once per session (23 s); later turns are cache
  hits (60–400 new tokens, 80–200 t/s on those tiny batches — pure per-request overhead).
- qwen-code's own accounting: 3.1 M input tokens for the Go session (of which 3.07 M cache reads) — the server's LCP
  cache reuse is what makes 75-turn sessions possible at all.

### Notes (North)

- 500K: the GGUF says 500 000; at 500K the KV would be ≈ +3.5 GiB → not GPU-only (needs
  `--n-cpu-moe` ≈ 18 layers). Kept at the card's 256K; revisit only if the winning model is judged on
  context.

## 2. Qwen3.5-9B Q8_0 with MTP head (T-1 safe)

`unsloth/Qwen3.5-9B-MTP-GGUF` `Qwen3.5-9B-Q8_0.gguf` (9.11 GiB, dense hybrid Gated-DeltaNet + attention, the MTP
draft layer `blk.32.nextn.*` inside the file), `MODEL_KWARGS={"enable_thinking":true}`, `--cache-ram 0` (pinned-cap
rule), card sampling temp 1.0 / top-p 0.95 / top-k 20.

### Fit (ctx = NP × 262 144, q8_0 KV)

| NP | `SPEC` | result |
|---|---|---|
| 4, 3, 2 | `draft-mtp,ngram-mod` | `failed to allocate Vulkan0 buffer of size 570425344` (a 544 MiB KV chunk) → `failed to allocate buffer for kv cache` |
| 2 | `ngram-mod` (no MTP: frees 2.1 GiB) | same failure — the doubled KV does not fit even with the MTP buffers gone |
| **1** | `draft-mtp,ngram-mod` | **UP in 8 s, 15 337 / 16 384 MiB**; `ngram-mod` or `none` alone: 13 171 MiB |

So, like North, qwen9b is **NP=1 at 262K** on this card. The MTP draft costs 2.1 GiB VRAM (its own 262K KV + compute
buffers) — worth it, see below.

### Speed — spec-decoding sweep (`sweep.sh qwen9b …`, 00:33–00:54, BIOS Cool, 150 s idle gaps, greedy, thinking on, 2 048 tok cap)

| config (`SPEC=`) | VRAM MiB | p0 rust-reverse: gen tok / t/s | p1 nginx-regex: gen tok / t/s | aggregate t/s | GPU start → end |
|---|---|---|---|---|---|
| `draft-mtp,ngram-mod` | 15 337 | 2 048\* / **27.15** | 2 048 / **22.97** | 24.90 | 55 → 70 °C |
| `draft-mtp` | 15 337 | 928 / **33.39** | 2 048 / **23.15** | **25.61** | 60 → 71 °C |
| `ngram-mod` | 13 171 | 928 / 19.09 | 2 048 / 13.55 | 14.91 | 60 → 71 °C |
| `none` | 13 171 | 928 / 18.25 | 2 048 / 11.83 | 13.30 | 60 → 72 °C |

\* under `draft-mtp,ngram-mod` p0 produced a *different* answer (still thinking at the 2 048 cap) — the batch-shape
non-reproducibility already seen on North; the other three configs produced the identical 928-token answer, so their
p0 numbers compare directly. p1 hit the cap in all four runs (at temp 0 qwen9b thinks > 2K tokens about an nginx
regex), so the p1 column compares directly everywhere.

- **The MTP head ≈ 1.8–2× decode** (33.4 vs 18.3 t/s cold, 23.2 vs 11.8 t/s hot/long) — the biggest single lever found
  on this box so far. `--spec-type draft-mtp` exits on models without the head (plan.md §5 trap), so it is per-model.
- `ngram-mod` alone: +5–15 %. On top of MTP: neutral on these prompts (22.97 vs 23.15, noise) — kept for the E2E
  because of the 90–95 % acceptance it gave North on whole-file re-emission.
- Hot-GPU penalty is larger than North's: p1 (second request, GPU 70 °C) runs at 65 % of p0 without speculation.
- Without speculation a dense 9B Q8_0 does 12–18 t/s — *slower* than North's 30B-A3B (22.7 no-spec) despite similar
  weight bytes per token: the Gated-DeltaNet recurrent ops are not where the Vulkan backend shines, and Cool mode keeps
  the SM at 300–1 000 MHz part of the time.

**E2E choice: `SPEC=draft-mtp,ngram-mod` (the models.sh default), NP=1, ctx 262 144.**

### Full test — the four-task E2E (`e2e-all.sh qwen9b`, 00:56–, `SPEC=draft-mtp,ngram-mod`, NP=1, ctx 262 144)

| task | wall | turns | tool calls (errors) | prompt tok (cold batch) | generated tok | tg t/s agg (min–max) | ctx max | draft acc. | verdict |
|---|---|---|---|---|---|---|---|---|---|
| rust | 136 s | 9 | 12 (3) | 25 828 (22 845 @ 721 t/s) | 2 270 | 26.8 (17.1–52.5) | 27.3K | 63.4 % | **FAIL 14/18**: `reverse()` right, tests pass, but `main()` iterates `stdin.lock().lines()` and prints the reversed *accumulated* input after **every line** (and nothing for empty input) instead of reading all of stdin once → multi-line inputs and `""` wrong; single-line inputs correct. A dead `if l.ends_with('\n')` check shows it did not know `lines()` strips the newline |
| go | 575 s | 27 | 30 (3) | 35 001 (22 993 @ 795 t/s) | 10 340 | 21.1 (13.9–34.0) | 39.0K | 62.1 % | **PASS 47/47**: vet/build/test clean, 147-line `main.go` + 242-line table-driven tests, `bufio.Reader`+`ReadAll`-style input so the 6 MB line is fine, `-n` semantics and tie-break exact. (Quirk: a bubble sort "for determinism in tests" — harmless here) |
| c | **interrupted** (≥ 48 min, 01:10–≥ 01:58) | ≥ 27 tool calls (54 tool results, 9 errors) | | | | 33–36 t/s early, **8.5–10 t/s at 100K** | ≥ 99.7K | | **not verified** — asgard went off the network at ≈ 02:05–02:13 while this session was at ≈ 100K context still debugging (`21` right, one operator printing `error`; `bignum.c` rewritten 802 → 624 → 525 lines, selftest earlier 7/20). Run `verify-c.sh` in `/data/ai/c-task-qwen9b/` when the box is back to score the last state |
| asm | not run | | | | | | | | resume: `./start.sh qwen9b && daemon -f -o ~/local-ai-runs/e2e-qwen9b.log ./e2e-all.sh qwen9b "c asm"` |

Speed notes: the MTP+ngram acceptance in agentic mode is **62–63 %** from the first turn (North: 17 % on rust), so
short tool-call turns run 17–34 t/s instead of North's 13–22; the price is the deeper-context decay: 8.5–10 t/s at
100K (North 13–15). Prompt batches at depth are slower than North's too (252–406 t/s at 25–40K vs 400–500).

**qwen9b so far**: 1 PASS (go, the medium task — North failed it), 1 FAIL on the easy task (rust, reads stdin line by
line), C unfinished at the outage. Quality on the two completed tasks is *at least* North's; it also debugs
persistently instead of regressing to stubs (54 tool results in the C session, real fixes, no fake selftest).

### Outage 02:09 CEST (2026-09-12) — hard freeze, not thermal

Forensics after the owner power-cycled the box at 05:55:

- `thermal.log` last status line **02:08:30**: core 65/62 °C, PCH 71 °C, GPU 74 °C, no HOT/CRITICAL event; the
  watchdog never fired (`WD_ACTION` = `shutdown -p`; a fired action logs an EVENT line and a syslog `daemon.crit`).
- `telemetry.csv` (5 s samples, local file) last row **02:09:01**: PCH 71, core 67, GPU 73 °C / SM 1 215 MHz / 89 %
  util / throttle 0x4, server up. `llama.log` last line at server-uptime 72:33 ≈ 02:09:1x: *"selected slot by LCP
  similarity"* — a new decode request starting at **113 485 tokens of context** (MTP+ngram speculation, C task).
- Nothing after that anywhere: no syslog line, no `shutdown time` record in `last` (unclean stop), `/var/crash`
  empty because `dumpdev="NO"` and there is **no swap/dump partition** at all (4 × 1.9 TB NVMe are ZFS end to end;
  ZFS cannot take kernel dumps), ACPI BERT empty (48-byte header only), `hw.mca.count` 0, pool healthy.
- Not a suspend (`hw.acpi.lid_switch_state=NONE`), not a Wi-Fi drop (the local logs stopped too), not power
  (adapter online, battery 100 % — although the battery could have recharged during the 3.7 h it sat off).

So: **an instant machine-level freeze or reset at ≈ 02:09:05, under GPU 89 % + CPU turbo 4.7 GHz, at the moment a
new request started at 113K context.** Cause undetermined; the prime suspect is a kernel-side nvidia/Vulkan fault
(the FreeBSD 595.99.02 driver under hours of sustained compute, deep-context KV/pinned staging traffic), the
alternative a power/EC event. `debug.debugger_on_panic=1` is set, so a kernel panic would have left a `db>` prompt on
the console — **what the screen showed at 05:55 (black/frozen X, `db>`, powered off) is the one missing datum.**

What was changed to make a repeat diagnosable: telemetry now logs `acline,batt_pct,batt_state`; the previous CSV is
kept as `~/local-ai-runs/telemetry-until-crash-0209.csv`. Options that need the owner: (a) **netdump** over the `em0`
Intel I219 (needs an Ethernet cable and `netdumpd` on tuxi — the only kernel-dump path without a swap partition);
(b) read the Dell BIOS System Event Log (F2 → System Logs) for a thermal/power event at 02:09.

The interrupted C attempt (preserved as `/data/ai/c-task-qwen9b.prev-*`, `verify-at-crash.txt`): 536 lines, strict
and sanitizer builds OK, but `make test` fails, selftest 2/24, arithmetic 421/420 wrong (even `0 + 0`) — it was
mid-rewrite after 58 min; scored **FAIL at cut-off**. The C and asm tasks were re-run from 06:02 (§ below).

### Thermal emergency action: `zzz` instead of power-off (owner question 05:57 → decision 06:2x)

Implemented in `/usr/local/sbin/thermal-watchdog` and **enabled**: `WD_ACTION="suspend"` in
`/usr/local/etc/thermal-policy.conf` (the old `"/sbin/shutdown -p now"` stays selectable, commented out next to it).
At CRITICAL (core ≥ 98 °C for 3 ticks, NVMe ≥ 87 °C for 2, PCH ≥ 115 °C) the watchdog caps the CPU at 1.2 GHz and
requests S3 (`acpiconf -s 3`): every heat source stops within seconds and the session survives; you resume with the
power button. A helper waits `WD_SUSPEND_GRACE` = 20 s of *run* time (`sleep` counts uptime, which stands still in
S3) and **powers off anyway if a critical sensor is still critical then** — S3 refused/hung, or resumed straight back
into the heat. After resume the watchdog resets its counters, keeps the cap and continues (it used to `exit` after the
action). At first the GPU job was deliberately left running across the suspend (owner decision: observe a real event
before assuming resume breaks anything) — the live test below showed it hangs, so since 08:18 the watchdog runs
`WD_SUSPEND_PRE` (`unstick.sh pre-suspend`: stop the server, remember it) under `timeout 15` right before the S3
request and `WD_SUSPEND_POST` (`post-resume`: start it again if it was running) after the resume; the power-off action
runs no hook (`ops.md` §3). Mock-tested twice with `acpiconf`/`shutdown` replaced by `echo` and the threshold forced
(06:0x: suspend request → resume line → escalation → loop continues, no double-fire; 08:16: pre-hook → suspend → back →
post-hook, a 40 s pre-hook cut at 15 s, no hook on power-off). Backups: `~/asgard-cfg/thermal/` on asgard and tuxi
(`thermal-watchdog.bak-20260912-{0605,0741,0818}`, `thermal-policy.conf.bak-…`).

### S3 live test 07:26 (owner request) — the server survives the suspend, its GPU work does not

Setup: qwen9b serving the resumed C task mid-generation (79 tool calls, ctx ≈ 129K, 28 t/s, VRAM 15 451 MiB, GPU
92 %; snapshot `~/local-ai-runs/zzz/live-c-pre.state`), `sudo zzz` at **07:26:12**, owner resumed at **07:28:01**
(93 s in S3; syslog `acpi: suspend at` / `resumed at` = devd ran `/etc/rc.suspend` and `/etc/rc.resume`).

Findings (`~/local-ai-runs/zzz/live-c-lldb.txt`):

- The process survived, `/health` ok, `/slots` "processing" the same task with `n_decoded` 0 forever, VRAM still
  allocated, **GPU 0 % / 18 W / 300 MHz**, all 44 threads sleeping. `lldb bt all`, main thread:
  `server_queue::start_loop → update_slots → decode → common_speculative_impl_draft_mtp::process →
  llama_get_embeddings_nextn → llama_context::synchronize → ggml_backend_vk_synchronize → ggml_vk_wait_for_fence →
  libnvidia-eglcore → poll()` — a fence submitted before S3 never signals; the 595.99.02 driver reports no device
  loss, no NVRM/XID in dmesg. Fresh Vulkan contexts work (`test-backend-ops -b Vulkan0 -o ADD`: OK). **SIGTERM is
  ignored** in that state (`stop.sh` escalated to KILL after 30 s, which freed the VRAM).
- qwen-code (12 h timeouts) waited silently — nothing self-heals without an external stall detector.
- Cost: the C run was scored at the cut (80 requests: **FAIL**, make=1) and continued with `qwen -r SID` after a
  server restart (UP in 6 s); the 128K prompt was re-ingested in ~7 min (535 → 300 t/s) because `--cache-ram 0`
  (pinned-cap rule) leaves no host-side prompt cache.

Remedies (07:35–08:20; the settled version is **`asgard/ops.md`**, owner rules 08:2x: a manual `zzz`/poweroff
does nothing with llama, only the thermal watchdog's suspend action does, the service is never in the boot sequence):

| piece | what it does |
|---|---|
| `unstick.sh check\|fix\|watch\|kill\|show\|pre-suspend\|post-resume` | finds the server by its port however it was started; stuck = slot processing **and** GPU 0 % for 60 s → diagnostics to `~/local-ai-runs/unstick/`, `kill -9`, restart by provenance: `start.sh --last`, or an identical relaunch of a hand-started server from the kernel's argv/env/cwd/binary (`kern.proc.args/env`, `procstat`) |
| thermal watchdog `WD_SUSPEND_PRE` / `WD_SUSPEND_POST` (`thermal-policy.conf` → `unstick.sh pre-suspend` / `post-resume`) | **the only automatic path**: right before the watchdog's S3 request the server is stopped (TERM, KILL after 3 s, hook hard-limited to 15 s) and its provenance saved; after the resume it is started again the same way, only if it was running; the power-off action runs no hook. Mock-tested 08:16 (order, 15 s cut-off, no hook on power-off) |
| `rc.d/llama` stub → `asgard/llamactl.sh start [MODEL]\|stop\|restart\|status` (rc.conf `llama_enable=YES`, `KEYWORD: nostart`) | `sudo service llama …` without ever being in the boot order; `start` without MODEL replays the last start; `status` is metadata-only |
| `e2e-test.sh` | self-heals: on `[API Error …]` it waits for `/health` and continues the same qwen session (`-r SID`, ≤ 3 times, `resumes=`/`downtime=` in the summary header); runs `unstick.sh watch 30` alongside every task; `RESUME=SID` for a manual continuation |
| `start.sh --last`, `zzz-probe.sh` | replay of the last start (`~/local-ai-runs/last-start.env`); the S3 probe used here (`state\|ref\|cmp\|pre\|task\|zzz\|post`) |

An interim universal hook (`rc.d/llama_s3` with `KEYWORD: suspend resume`, run by devd's `/etc/rc.suspend` /
`rc.resume` for every suspend) was built, verified against the syslog `acpi: suspend at` / `resumed at` lines of the
07:26 test, and removed again at 08:18 on the owner's rule that a manual `zzz` must not touch llama.

Caught while wiring it up (08:03): `asgard/health.sh` ends with a real completion ("Reply with exactly: OK") — with
NP=1 it queued behind the C task and would have evicted its 149K cache; killed in time (server logged `cancel task
2870`, the task was unharmed). **Rule: never `health.sh` while a task runs**; the service and unstick use only
`/health`, `/props`, `/slots`.

Still open: S3 with an *idle* server (no request in flight) — `zzz-probe.sh pre / zzz / post` would show whether the
context survives (the owner's call before a manual `zzz`). The live cycle of the watchdog hooks (`unstick.sh
pre-suspend` → `post-resume`, start.sh and hand-started provenance) and `service llama stop/start` are exercised on
the idle server between the C and asm tasks (§ below).

## E2E tasks — the four-task suite (`e2e-tasks.sh`, `e2e-test.sh`, `e2e-all.sh`, `verify-*.sh`)

Each task is one headless qwen-code session (`qwen.sh --yolo -o stream-json`, `contextWindowSize` 262 144,
`autoCompactThreshold` 0.95, 4 h cap) against the model under test; the model must create the project, build, test and
fix it itself. Afterwards an **independent verifier** (never shown to the model) builds the spec'd source only and checks
behaviour against a Python/coreutils reference; its `VERDICT:` line is the strict pass/fail. Everything is preserved in
`/data/ai/<task>-task-<model>/` (`summary.txt` with server-side timings and per-request table, `qwen.log`, `verify.txt`,
the project). `e2e-all.sh MODEL` runs the four in order with 60 s gaps and prints the comparison table.

| # | task | language / toolchain | what the prompt demands | verifier (`verify-*.sh`) | why it is in the ladder |
|---|---|---|---|---|---|
| 1 | **rust** (easy) | Rust, `cargo` | `revstr`: `reverse(&str)` by Unicode scalar values; `main` reads stdin, strips **one** trailing newline, prints reversed + `\n`; unit tests incl. Polish and emoji; `cargo build --release` + `cargo test` green | build/test; 9 inputs × with/without trailing newline vs Python `[::-1]`; layout-agnostic (`revstr/` or root) | the baseline "can it drive cargo and get a 30-line program exactly right" |
| 2 | **go** (medium) | Go 1.27, stdlib only | `wordfreq`: top-N words from stdin; word = run of `IsLetter||IsDigit`, folded with `ToLower`; `count\tword`, count desc then word asc; `-n` (default 10, `< 1` → stderr + exit 2); table-driven tests for 6 named cases; `go vet`/`build`/`test` green | vet/build/test; 11 texts × `-n 10/1/3/100` + default + `-n 0` vs Python `re.findall(r"[^\W_]+")`; a **6 MB single-line** input (perf + buffering sanity) | precise spec with several easy-to-miss clauses (tie-break, exit codes, Unicode classes, big input) |
| 3 | **c** (harder) | C11, `cc -Werror`, bmake + gmake | `bignum`: signed arbitrary-precision `+ - *` on decimal strings up to 10 000 digits, canonical output, `error` for malformed lines, no fixed limits, ASan/UBSan-clean, `--selftest` with ≥ 20 `assert`s incl. a 100×100-digit product, Makefile `all/test/clean` for both makes | strict `-Werror` build of **bignum.c only**, ASan+UBSan build, `make`/`make test`, selftest under ASan, 20 edge + 400 random lines vs Python ints, malformed/blank lines, empty input | algorithmic work + memory discipline + a self-test the model can fake (and North did) |
| 4 | **asm** (hardest, long-context) | x86-64 GNU as 2.44 + `ld`, **no libc**, FreeBSD syscalls | `b64`: streaming base64 encoder and `-d` decoder over stdin/stdout; short `read`/`write` handling, leftover carry across reads, newline-tolerant decoder, exit 1 on invalid input / I/O error, exit 2 usage; the prompt carries **700 acceptance vectors (`VECTORS.txt`, ≈ 57K tokens) on stdin** so the session starts at ≈ 80K context and the model's own work is expected to push it past 128K | as+ld, static/nolibc (`nm -u`, `ldd`), regenerated vectors both directions, 20 blob sizes up to 1 000 003 B vs `base64`, delayed-pipe short reads, wrapped input, 5 decoder-error cases → 1, usage → 2, no trailing newline, `make`/`make test` | OS-specific knowledge (FreeBSD syscall numbers/ABI), bit manipulation, and a genuine ≥ 128K-token multi-turn session where the input does not eat the window |

Vectors come from `e2e-vectors.py N` (seed 20 260 911, hex ↔ base64, lengths 0–~3 KB); the verifier regenerates them
rather than trusting the copy the model saw. All verifiers were validated against my own reference implementations
before any model ran (Go 47/47, C 420 lines, ASM 15/15 + toolchain).
