# asgard local-AI — LIVE STATUS (restart sheet)

**Purpose:** the one file to read after a crash of the operator VM, of asgard, or of the chat session. It says what is
running, what is done, what is next and how to resume — nothing else. Updated by the operator (copilot) at every transition
(chain start/stop, phase change, incident, verdict); each update carries a CEST timestamp. History and evidence live in
`results-t*.md` / `ops.md`; this file only points there. Owner commits `/data/local-ai` (last: "Update status 23", 15 Sep 11:52; pending: `asgard-deployment/README.md` +
`llama-tier.sh` and this doc refresh).

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
| T2 `best\|t2` | **frozen 15 Sep 11:20** (quality first) | `flashnext` Qwen3.8-Flash-Next UD-IQ4_XS, `NCMOE=47 THREADS=16 SPEC=none`, thinking on, effort xhigh (= its max) | 79 (pinned only) | 3.3 / 2.8 bench, **3.0 codebench**, E2E 2.5–2.7 (healthy est. 3.9–5.3, never measured) | **always** (every T2 load) | PASS 5/5 ×2 | PASS 5/5 (run 1: 47/47 functional, FAIL-infra on the test check) | PASS 5/5 (463 min) | not run (phase C off) | results-t2.md §3.4 tally + §4 verdict; `qwen122b` / `qwen122b-iq4` **deleted 11:15** (their rows stay in results-t2.md §3) |

Pinned/healthy factors (results-t1.md §6.1): all-VRAM ×3.8 tg / ×4.6 pp; T1-class (half the experts in RAM) ×2.9 tg / ×8.7 pp;
T2-class unknown (never ran healthy) — the §6.1 estimate is ×1.3–1.8 tg, so `flashnext` would be ~3.9–5.3 t/s on a healthy GPU.

Disk (`/data/local-ai/models`): the T0 file (10.7 GiB), the T1 file (20.8 GiB), the three `flashnext` shards (87.3 GiB). Nothing
else — the six Qwen3.5-122B shards (~130 GB) were deleted 15 Sep 11:15 on the owner's order.

## What is running right now — 15 Sep 14:15 CEST

- **`flashnext` asm task (phase C), GPU UN-PINNED, on the owner's rc.d service** — the owner started `sudo service llama-t2 start` 13:58
  (UP 47 s, VRAM 14 191 MiB, `HW Power Braking 0 us`, first hello-world request: pp 78.7 t/s over the 25.8K system prompt, tg 4.9 t/s)
  and asked for the 4th task with results/speed recorded as usual **plus the un-pinned note**. Launched 14:12:22 (`pch=70 gpu=36C`):
  `daemon -f -o ~/local-ai-runs/e2e-flashnext-asm.log env LOG=~/local-ai-runs/llama-t2.log E2E_UNSTICK=0 E2E_CAP=28800
  E2E_NOTE="GPU UN-PINNED ..., server = rc.d llama-t2 deployment service, cap 8 h" ./e2e-all.sh flashnext asm` (cap 8 h → ends by
  22:12 at the latest). `LOG=` points the timing-slice parser at the service log; `E2E_UNSTICK=0` and `last-start.env` moved to
  `~/local-ai-runs/last-start.env.hold` so the harness can never kill/restart the owner's service via the research `start.sh --last`
  (**restore `last-start.env` when the run is over**). health.sh: `OK`, pp 20 / tg 5.9 t/s (28 tokens). `telemetry.sh` running again
  (GUARD_PCH=108, pid file `~/local-ai-runs/telemetry.pid`, CSV appends). Owner's `vcp` copy over `/asgard` (sftp-server, ~30 MB/s
  into the 4-way mirror) may overlap — minor CPU/NVMe load, noted if it does.
  Progress: `tail -f ~/local-ai-runs/e2e-flashnext-asm.log`; `ls -la /data/ai/asm-task-flashnext`; `grep -c '"type"' …/qwen.log`;
  `sudo service llama-t2 status` (slot busy/idle); owner's `temp.sh` or `tail -3 ~/local-ai-runs/telemetry.csv`.
  Result goes to results-t2.md §3.5 (new), report-t2.md, the T2 row of the tier table above, ops.md.
- **Research is over: T0, T1 and T2 are frozen** (T2 = `flashnext`, 15 Sep 11:20, results-t2.md §4; report-t2.md is final). The daily-use
  deployment is **`/data/local-ai/asgard-deployment/`** (its README.md is the cheat sheet): `sudo service llama-t0|llama-t1|llama-t2
  start|stop|status|restart [yarn2]` — installed 11:33, every path tested 11:34–12:07 (t0/t1/t2 start/status/stop, one tier at a time,
  `qwen.sh` / `qwen-tN.sh` clients on asgard and tuxi, YaRN x2 on all three tiers, x4 refused). **Nothing starts at boot** (KEYWORD nostart).
- The research path (`asgard/start.sh|stop.sh`, rc.d `llama` stub, `llama_enable=YES`) still exists and shares the port; the tier launcher
  refuses to start while it runs (`asgard/stop.sh` first).
- Owner's announced next step: restart asgard and test UEFI settings against the GPU pin (AC Adapter Type / Peak Shift).

## Done 15 Sep — pointers

- 07:01–11:08 chain 3 (second rust + go sample, all pinned) → results-t2.md §3.4 + final tally: `flashnext` **0** / `qwen122b-iq4` 2 /
  `qwen122b` 3 functional failures in 5 runs each (the 122B go failure is deterministic: default `bufio.Scanner` 64 KiB limit vs the 6 MB line).
- 11:15 owner: "flash wins, so delete other T2 models" → both Qwen3.5-122B quantisations deleted (6 shards + `.verified` markers, ~130 GB);
  11:20 `best|t2` frozen in `models.sh` (`flashnext`, k=47, 16 thr, SPEC none), qwen122b entries removed; smoke test `start.sh best` UP 49 s.
- 11:33–12:07 deployment `asgard-deployment/` (rc.d stubs, `llama-tier.sh`, `qwen*.sh`, installers, README): t0 UP 15 s, t1 22 s, t2 53 s
  (rendered prompt "Reasoning effort is set to xhigh"), tuxi clients through the ssh tunnel, yarn2 on t0/t1/t2 (t2 needs batch 1024/512),
  yarn4 refused → ops.md 15 Sep bullets, asgard-deployment/README.md.
- 13:20 direct Ethernet link tuxi `ue0` 10.10.10.1 <-> asgard `em0` 10.10.10.2 (`asgard-eth` / `tuxi-eth`), `/asgard` sshfs mount on tuxi
  (`/data/scripts/mount-asgard.sh`, ROOT mount with allow_other); 30 MB/s because the AX88179B adapter only ever links at USB 2.0 — tested
  on three tuxi ports incl. a root port, not a driver limit → try it on asgard's USB-A, else replace (ops.md 13:20). GPU un-pinned after
  the owner's restart. 13:38 NVMe temps OK on both hosts during the owner's `vcp` copy; asgard nvme3 is the hot one (ops.md).


## Done 14 Sep — pointers

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

1. **Operator: STOP** (owner's instruction once the deployment is done). Owner restarts asgard for the UEFI pin tests; after that boot the
   GPU is healthy — the first T2 (or T1-class) load pins it again (expected, results-t1.md §6.2).
2. Owner: `git add -A && git commit` in `/data/local-ai` (asgard-deployment/README.md + llama-tier.sh, this doc refresh), `git pull` on tuxi
   (the `qwen*.sh` copies in tuxi `/data/scripts` are already current — installed 11:38, tunnel fix 11:48).
3. Optional / on request: phase C (asm) for `flashnext` (cap ≥ 8 h at 3 t/s); `E2E_CAP=28800` asm rerun of the T1 winner; healthy-regime T2
   speed (needs a load that does not trip the adapter = the UEFI work); remove the research rc.d `llama` stub + `llama_enable` from rc.conf
   once the tier services are trusted; report-t2.md polish.
4. Leftovers to delete when convenient: asgard `/tmp/bignum-*`, `/tmp/leakprobe*`, `/tmp/memleak*`, `/tmp/check_vectors.py` (the c-task
   agents' scratch); VM `/tmp/t1`.

## How to resume after a crash

- **If the asm run above was cut** (asgard or VM crash): server first (`sudo service llama-t2 start`, wait for UP), then
  `cd /data/local-ai/asgard && SID=$(grep -o '"session_id":"[0-9a-f-]*"' /data/ai/asm-task-flashnext/qwen.log | tail -1 | cut -d'"' -f4);
  RESUME=$SID LOG=~/local-ai-runs/llama-t2.log E2E_UNSTICK=0 E2E_CAP=28800 E2E_NOTE="GPU UN-PINNED, rc.d llama-t2, resumed" daemon -f -o
  ~/local-ai-runs/e2e-flashnext-asm-resume.log ./e2e-test.sh flashnext asm` (existing dir kept, summary/per-request `.prev-*`); check the
  GPU pin state after the reboot first (a T2 load can pin it again — then the speed part of the record is pinned, say so). Afterwards
  `mv ~/local-ai-runs/last-start.env.hold ~/local-ai-runs/last-start.env`.
- Research is finished — nothing else needs resuming. Daily use: `asgard-deployment/README.md`. A tier service that was running when asgard
  died does **not** come back at boot (by design): `sudo service llama-tN start` again; the launcher cleans stale pidfiles itself.
- After any asgard boot: `GUARD_PCH=108 daemon -f -p ~/local-ai-runs/telemetry.pid /data/local-ai/asgard/telemetry.sh
  ~/local-ai-runs/telemetry.csv` (telemetry does not survive a reboot); `sudo grep acpi_acad0 /var/log/messages | tail` = drop count;
  `nvidia-smi --query-gpu=clocks.sm,pstate --format=csv` = pin state (1035 MHz / P2 = pinned).
- **Never** start a model load "to check" right after a healthy boot if the goal is to keep the healthy regime (drops #6/#7).
