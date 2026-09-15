# asgard local-AI — LIVE STATUS (restart sheet)

**Purpose:** the one file to read after a crash of the operator VM, of asgard, or of the chat session. It says what is
running, what is done, what is next and how to resume — nothing else. Updated by the operator (copilot) at every transition
(chain start/stop, phase change, incident, verdict); each update carries a CEST timestamp. History and evidence live in
`results-t*.md` / `ops.md`; this file only points there. Owner commits `/data/local-ai` (everything since "Update status 14",
13 Sep 20:58, is uncommitted).

---

## Standing rules (owner; do not re-ask)

- Autopilot; short chat answers; the owner commits git; `/data/local-ai` on asgard is the source of truth.
- **Ranking rule:** tier winner by **coding output quality** (E2E rust/go/c/asm grades via `scoreboard.py`), speed second;
  keep every model on disk unless the owner says otherwise (T1 non-winners were deleted on his order, 14 Sep 11:48).
- **Never:** `nvidia-smi -pl/-lgc/-pm/-r`, driver reload, reboot/power-off unprompted (power-off only when the owner offers),
  `pkill` (kill specific PIDs), GPU `llama-bench`, anything in `/var/tmp`, editing a running `sh` script in place (kill →
  scp to /tmp + `mv` → restart), heredocs with backticks inside `ssh asgard '…'` (write under `/tmp/t1/` on the VM and scp, or
  scp a python patch script and run it), printing secrets, e-mails to anyone.
- Distinguish **FAIL-infra / FAIL-task-score / PASS-score** in every result table. Leave the thermal watchdog config alone.
- GPU pin (1035 MHz / P2 after an `acpi_acad0: Off Line` event) is **the T2 operating regime** with the current adapter
  (results-t1.md §6.2 amendments 11:53–12:30): 7/7 first partial-offload prefills tripped the adapter, the pin never trips.
  Do not request cold power-offs for T2 work; label speed rows `-pin`; quality is regime-independent.

## Tier state

| tier / profile | state | winner (frozen knobs) | **pp in t/s** (healthy → pinned) | **tg out t/s** (healthy → pinned) | **pins the GPU?** | rust | go | c | asm | where |
|---|---|---|---|---|---|---|---|---|---|---|
| T0 `vram\|t0` | **frozen 13 Sep** | `qwen35b` Qwen3.6-35B-A3B UD-IQ2_M, all-VRAM, `SPEC=none NCMOE=0` | 1 362 → 294 (depth 2 048) | 61.5 (codebench 60.6) → 16.0 | **never** (all-VRAM; 0 drops in ~30 h) | PASS 5/5 | PASS 5/5 | 4/5 (malformed lines) | 2/4 (4-h cap) | results-t0.md §4–5, report-t0.md §6 |
| T1 `fast\|t1` | **frozen 14 Sep 07:20** | `qwen35b-q4` UD-Q4_K_XL, `NCMOE=20 THREADS=8 SPEC=none` | 831 → 96 | 32.5 (codebench 31.4) → 11.0 | **can** — 3 of 7 drops were T1-class loads, not every load | 4/5 spec-only (0 functional) | PASS 5/5 | PASS 5/5 | 0/4 (cap) | results-t1.md §6, §6.1–6.3 |
| T2 `best\|t2` | **in progress** (winner by quality) | `qwen122b` Qwen3.5-122B-A10B UD-Q4_K_XL, k=47 MTP | 82 (pinned only) | 5.9 / 5.6 bench (depth 64 / 4 096), **4.3 codebench** | **always** (5/5 T2 loads) | 4/5 (first line only) | 4/5 (Scanner 64 KiB) | **PASS 5/5** (98 min, 39 turns, 3.9 t/s) | off by default | results-t2.md §2.5, §3 |
| | | `qwen122b-iq4` UD-IQ4_XS, k=47 MTP | 77 (pinned) | 4.9 / 5.2 bench, **3.5 codebench** | **always** | PASS 5/5 | 4/5 (Scanner 64 KiB) | **PASS 5/5** (141 min, 40 turns, 3.6 t/s) | off | |
| | | `flashnext` Qwen3.8-Flash-Next UD-IQ4_XS, k=47 none, 16 thr (no MTP layers) | 79 (pinned) | 3.3 / 2.8 bench, **3.0 codebench** | **always** | PASS 5/5 ×2 | run 1: 47/47 functional, tests cut (infra); **run 2: PASS 5/5** (79 min) | **PASS 5/5** (7 h 43 min, 45 turns, 2.5 t/s, 66.9K tokens) | off | |

Pinned/healthy factors (results-t1.md §6.1): all-VRAM ×3.8 tg / ×4.6 pp; T1-class (half the experts in RAM) ×2.9 tg / ×8.7 pp;
T2-class unknown (never ran healthy) — the §6.1 estimate is ×1.3–1.8 tg, so `qwen122b` would be ~7–10 t/s on a healthy GPU.

Disk (`/data/local-ai/models`, 250 GB used): the T0 file, the T1 file, the three T2 files. Nothing else.

## What is running right now — 15 Sep 09:20 CEST

- **`t2-chain1.sh`: DONE** 13:22 (results-t2.md §2.5). **Phase A of chain 2: DONE** 17:14 (results-t2.md §3.1 + summary table):
  `qwen122b` 2 functional failures, `qwen122b-iq4` 1, `flashnext` 0 (go cut by the owner's power-off after the program was complete).
- **`t2-chain2.sh` (PHASES=DB, 14 Sep 17:44 → 15 Sep 07:00): DONE** (GPU pinned since drop #8 at 17:37:45 — the turbo-off experiment, see below). **Phase D DONE 19:05** (§3.2): `qwen122b` **4.31**, `qwen122b-iq4` **3.49**, `flashnext` **2.96** t/s pinned. **Phase B running since 18:56**: `qwen122b` c **PASS 5/5** in 98 min (18:58–20:40, results-t2.md §3.3 — the first T2 result better than T0's and equal to T1's); `qwen122b-iq4` c **PASS 5/5** in 141 min (20:47–23:08); `flashnext` c **PASS 5/5** in 7 h 43 min (23:11–06:58, 17 min under the cap; 45 turns, 66.9K generated tokens). **Chain 2 DONE 07:00:46** (end pin check 16.24 t/s PINNED). **`t2-chain3.sh` running since 07:01** (results-t2.md §3.4: flashnext go run 2 **PASS 5/5** 79 min at 08:26; flashnext rust run 2 **PASS 5/5** 37 min at 09:04 — flashnext 5/5 runs clean; `qwen122b` rust+go run 2 running 09:11 → (~50 min); then `qwen122b-iq4` rust+go (~50 min) → chain end ~11:00) — a **second phase-A sample** (rust + go, cap 4 h, pinned) for `flashnext` (go first — its run-1 go is FAIL-infra on the unit-test check), `qwen122b`, `qwen122b-iq4` (~3.5–4 h → done ~10:30–11:30 15 Sep; log `~/local-ai-runs/t2-chain3.log`; run-1 projects are kept as `/data/ai/TASK-task-MODEL.prev-TS`). Reason: the quality ranking (qwen122b 2 / iq4 1 / flashnext 0 functional failures) rests on one sample per task at temperature 1.0 — two samples × 2 tasks + c make the §4 verdict defensible. Then §4 verdict + report-t2.md (**draft written 23:58**: §1–4 and §7 final, §5/6/8–10 pending). Chain design: pin check → **phase D** pinned codebench per model (`cpu47-mtp-pin-code`
  for the qwen122b files, `cpu47-none-pin-code` for flashnext with THREADS=16; ~15 min each) → **phase B** c task per model (cap 8 h
  each, pinned; T1's c took 54–118 min at 4–6× our speed → expect 3–8 h per model, i.e. into 15 Sep). Phase C (asm) is **off** by
  default (FAIL-infra by cap at 2.5–5.6 t/s); `PHASES=DBC` if the owner wants it.
  Logs: `~/local-ai-runs/t2-chain2.log`, `~/local-ai-runs/e2e-MODEL.log`, `sweep-MODEL.csv` (`*-code,TOTAL` rows); projects
  `/data/ai/c-task-MODEL/summary.txt`. Touch `~/local-ai-runs/t2-stop` to end the chain after the current task.
- **`telemetry.sh`** running again since 17:23 (`~/local-ai-runs/telemetry.csv`, 5 s samples, GUARD_PCH=108) — it does **not** survive
  a reboot: restart it after every boot (`GUARD_PCH=108 daemon -f -p ~/local-ai-runs/telemetry.pid /data/local-ai/asgard/telemetry.sh
  ~/local-ai-runs/telemetry.csv`).
- **Pin is unavoidable from software (17:36–17:40 experiment):** CPU turbo disabled, `qwen122b` load + ramp on a healthy GPU → AC drop
  #8 0.6 s after the GPU's first 1950 MHz / 100 W boost, CPU at 1.3 GHz. Mechanism = EC **hardware power-brake** (`nvidia-smi -q -d
  PERFORMANCE` → "HW Power Braking" counter > 0 in the session that got pinned; 0 in sessions that start pinned). `/data/scripts/temp.sh`
  shows `boost-lock: PINNED/none/unclear` on the GPU line (AC drops since the last boot marker + SM/util samples with a client). Adapter = 240 W Dell original (owner) → open hardware checks in results-t1.md §6.2 (BIOS "AC Adapter Type", Peak
  Shift, jack/centre pin). Do not spend cold power-offs on T2 any more.

## Done today (14 Sep) — pointers

- 09:00–11:10 qwen122b load failure root-caused (NVIDIA driver host-visible allocation windows `[n·256 MiB, +≈14 MiB)`),
  **patch 0002 v2** built into both binaries, runtime-verified 11:53 (`padded to n·256+128 MiB`) — results-t2.md §2.3, ops.md.
- 10:26–11:47 pinned pass: fits + bench rows for both qwen122b files — results-t2.md §2.4 (tables).
- 11:43–11:48 T1 non-winners `kat-q4` + `qwen35b-q8` deleted, `models.sh` cleaned — results-t1.md §6 update paragraph.
- 11:50–12:30 cold power-offs #6/#7 → AC drops #6 (11:53, built-in warm-up) / #7 (12:22, 4 s into the ramp) → `--no-warmup`
  (serve.sh) + `ramp.py` (gap-free ramp before every first request; start.sh / bench.py / codebench.py / e2e-test.sh) kept;
  verdict "T2 always pinned with this adapter" — results-t1.md §6.2 amendments, results-t2.md §2.4 postscripts.
- 12:25–13:22 pinned continuation rows complete (`cpu48-mtp`: the nextn block alone is the k=47 gain; flashnext has **no MTP
  layers** in its file, +23 % with THREADS=16) — **results-t2.md §2.5 table** = the T2 speed reference (pinned regime).

## Next (in order)

1. ~~Chain 1~~ done (§2.5).
2. ~~Phase A~~ done (§3.1). Chain 2 `PHASES=DB`: phase D codebench rows → §3.2 speed table; phase B c task → §3.1 rows; update this
   file after every result (B is an 8 h cap × 3 models — expect the run to span into 15 Sep).
3. Phase B results → §3.2; then the T2 verdict by quality. Current standing: no T2 model beats the T1 winner (0 functional failures)
   yet; `flashnext` is the only clean one. If nothing beats it, `best|t2` may stay unfrozen or point at the best-by-quality with the
   caveat written down (owner's call — ask with the data).
4. T2 verdict by quality → freeze `best|t2` in models.sh, write `report-t2.md`; then cleanup (`/tmp/pinprobe*`,
   `/tmp/b2-compile.log` on asgard; `/tmp/t1` on the VM) and remind the owner to commit.
5. Open owner items: BIOS "AC Adapter Type" / Peak Shift / jack centre-pin check (results-t1.md §6.2 — adapter is 240 W); optional
   `E2E_CAP=28800` asm rerun of the T1 winner; phase C (asm) for T2 only on request.

## How to resume after a crash

- **VM/session died, asgard fine:** `ssh asgard 'ps -axo pid,etime,command | grep -E "t2-chain|sweep.sh|llama-server|e2e"'`,
  `tail ~/local-ai-runs/t2-chain{1,2}.log`, the CSVs and `e2e-*.log` above; the chains are `daemon`-detached and survive.
  Continue from "Next". Local helper copies of the chain scripts: VM `/tmp/t1/` (may be gone after a VM crash — the asgard
  copies in `~/local-ai-runs/` are the truth).
- **asgard crashed/froze:** owner power-cycles. Then: `sudo grep acpi_acad0 /var/log/messages | tail` (drop count), GPU state
  `nvidia-smi --query-gpu=clocks.sm,pstate --format=csv`, check `/data/ai/*-task-*/summary.txt` for the task that was running
  (FAIL-infra if cut), restart chain 2 with `PHASES=` set to the remaining phases:
  `PHASES=BCD daemon -f -o ~/local-ai-runs/t2-chain2.log ~/local-ai-runs/t2-chain2.sh` (rotate the log first; chain 2 skips
  its chain-1 wait when `PHASES` is set). Chain 1 needs no rerun once `T2_CHAIN1_DONE` is in its log.
- **Never** start a manual model load "to check" right after a healthy boot: it costs the healthy regime within seconds (drops #6/#7).
