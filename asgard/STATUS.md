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

| tier | state | winner / candidates | where |
|---|---|---|---|
| T0 `vram\|t0` | **frozen 13 Sep** | `qwen35b` (Qwen3.6-35B-A3B UD-IQ2_M, all-VRAM) 60.6 t/s; E2E rust 5/5 go 5/5 c 4/5 asm 2/4 | results-t0.md §4, report-t0.md |
| T1 `fast\|t1` | **frozen 14 Sep 07:20** | `qwen35b-q4` (UD-Q4_K_XL, `NCMOE=20 THREADS=8 SPEC=none`) 31.4 t/s; rust 4/5 spec-only, go 5/5, c 5/5, asm 0/4 (cap) — 0 functional failures | results-t1.md §6, §6.3 |
| T2 `best\|t2` | **in progress** | `qwen122b` (Qwen3.5-122B-A10B UD-Q4_K_XL, MTP), `qwen122b-iq4` (UD-IQ4_XS, MTP), `flashnext` (Qwen3.8-Flash-Next UD-IQ4_XS, **no MTP layers** in the file) — all `bestk` = 47 | results-t2.md §2.3–2.5 |

Disk (`/data/local-ai/models`, 250 GB used): the T0 file, the T1 file, the three T2 files. Nothing else.

## What is running right now — 14 Sep 15:10 CEST

- **`t2-chain1.sh`: DONE** 13:22 (`T2_CHAIN1_DONE`; all pinned placement rows in results-t2.md §2.5). No rerun needed.
- **`t2-chain2.sh`** (PIDs 87577 daemon / 88041 sh, started 12:25): **phase A** — `qwen122b` done (rust 4/5, go 4/5, both
  FAIL-task-score "all of stdin" slips); **`qwen122b-iq4` k=47 MTP: rust PASS 5/5 (16 min), go running since 14:48**; then
  `flashnext` (k=47 none) rust+go. Then phase B (c, cap 8 h × 3), C (asm, cap 8 h × 3), D (pinned codebench × 3). All pinned.
  Logs: `~/local-ai-runs/t2-chain2.log`, `~/local-ai-runs/e2e-MODEL.log`; projects `/data/ai/TASK-task-MODEL/summary.txt`
  (results table: results-t2.md §3.1). Touch `~/local-ai-runs/t2-stop` to end the chain after the current task.
- Expected timeline (pinned): phase A ≈ until 16:30; B ≈ 16:30 → 15 Sep early morning; C after that. The operator polls every ~20–30 min.
- Interim quality picture: `qwen35b-q4` (T1, 0 functional failures) > `qwen122b` (2 functional failures); `qwen122b-iq4` clean so far.

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
2. Chain 2 phase A → grade with `scoreboard.py`, results-t2.md **§3** table (PASS-score / FAIL-task-score / FAIL-infra), update
   this file after every model. Phases B/C/D likewise (B+C are ~8 h caps each × 3 models — expect the run to span into 15 Sep).
3. T2 verdict by quality → freeze `best|t2` in models.sh, write `report-t2.md`; then cleanup (`/tmp/pinprobe*`,
   `/tmp/b2-compile.log` on asgard; `/tmp/t1` on the VM) and remind the owner to commit.
4. Open owner items: adapter label / BIOS adapter type / jack check (the only real fix for the pin); optional `E2E_CAP=28800`
   asm rerun of the T1 winner.

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
