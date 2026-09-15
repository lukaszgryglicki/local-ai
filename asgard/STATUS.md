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
- Distinguish **FAIL-infra / FAIL-task-score / PASS-score** in every result table. Thermal watchdog: the owner authorised policy
  changes on 15 Sep 14:35 (backup first — `asgard/backup-thermal-20260915/`); current policy in ops.md §3.
- GPU pin (1035 MHz / P2 / ≤57 W after an `acpi_acad0: Off Line` event) = **a power-budget derating latched by the EC/BIOS until a
  cold power-off** (not a clock lock, not GPU thermal management — ops.md §8.4): the driver's power limit drops to ≈65 W (SW Power
  Cap engages) and the EC asserts the HW power-brake pin under load; brief boosts to 1875 MHz still happen, so single SM samples
  lie — `temp.sh` reads the brake counter (fixed 15:40). 10 of ~12 first partial-offload GPU steps tripped the adapter so far (#11 at
  16:11:52 on a fresh cold boot, 3 s after UP, with `--lazy-mode off`); an adapter re-plug does not clear it, only a cold power-off.
  **Owner 16:14: "pinned is the reality — do NOT power off, settle everything and run T2 pinned"** → no more power-off requests; every
  speed row is `-pin` unless it says otherwise; quality is regime-independent. The one un-pinned T2 sample: results-t2.md §3.5.
- **Every model fully in VRAM+RAM, never lazily from disk** (owner, 15 Sep 15:50): `--load-mode none --lazy-mode off` in every launcher;
  `models/` dataset stays `primarycache=metadata` so the model is not duplicated in the ARC.

## Tier state

| tier / profile | state | winner (frozen knobs) | **pp in t/s** (healthy → pinned) | **tg out t/s** (healthy → pinned) | **pins the GPU?** | rust | go | c | asm | where |
|---|---|---|---|---|---|---|---|---|---|---|
| T0 `vram\|t0` | **frozen 13 Sep** | `qwen35b` Qwen3.6-35B-A3B UD-IQ2_M, all-VRAM, `SPEC=none NCMOE=0` | 1 362 → 294 (depth 2 048) | 61.5 (codebench 60.6) → 16.0 | **never** (all-VRAM; 0 drops in ~30 h) | PASS 5/5 | PASS 5/5 | 4/5 (malformed lines) | 2/4 (4-h cap) | results-t0.md §4–5, report-t0.md §6 |
| T1 `fast\|t1` | **frozen 14 Sep 07:20** | `qwen35b-q4` UD-Q4_K_XL, `NCMOE=20 THREADS=8 SPEC=none` | 831 → 96 | 32.5 (codebench 31.4) → 11.0 | **can** — 3 of 7 drops were T1-class loads, not every load | 4/5 spec-only (0 functional) | PASS 5/5 | PASS 5/5 | 0/4 (cap) | results-t1.md §6, §6.1–6.3 |
| T2 `best\|t2` | **frozen 15 Sep 11:20** (quality first) | `flashnext` Qwen3.8-Flash-Next UD-IQ4_XS, `NCMOE=47 THREADS=16 SPEC=none`, thinking on, effort xhigh (= its max) | 79 pinned (short prompt); 82K-token re-prefill **44 pinned → 135 un-pinned**, ramp step 98 → 260 (§3.5) | 3.3 / 2.8 bench, **3.0 codebench**, E2E 2.5–2.7 pinned → **5.5–5.9 un-pinned** (§3.5, 1 725 tokens) | **always** (every T2 load) | PASS 5/5 ×2 | PASS 5/5 (run 1: 47/47 functional, FAIL-infra on the test check) | PASS 5/5 (463 min) | not run (phase C off) | results-t2.md §3.4 tally + §4 verdict; `qwen122b` / `qwen122b-iq4` **deleted 11:15** (their rows stay in results-t2.md §3) |

Pinned/healthy factors (results-t1.md §6.1): all-VRAM ×3.8 tg / ×4.6 pp; T1-class (half the experts in RAM) ×2.9 tg / ×8.7 pp;
T2-class measured 15 Sep 14:44–14:59 (results-t2.md §3.5): **×1.7–1.8 tg, ×3.1 long-prompt pp, ×2.7 short-prompt pp** — tg matches the
§6.1 estimate, pp is far above it (the GPU does the prefill, decode is CPU-expert-bound).

Disk (`/data/local-ai/models`): the T0 file (10.7 GiB), the T1 file (20.8 GiB), the three `flashnext` shards (87.3 GiB). Nothing
else — the six Qwen3.5-122B shards (~130 GB) were deleted 15 Sep 11:15 on the owner's order.

## What is running right now — 15 Sep 16:20 CEST

- **`flashnext` asm task (phase C), GPU PINNED, `--lazy-mode off`, on the rc.d `llama-t2` service (pid 86085, started 16:10:43, UP 66 s,
  VRAM 14 244 MiB).** Launched 16:16:03: `daemon -f -o ~/local-ai-runs/e2e-flashnext-asm.log env LOG=~/local-ai-runs/llama-t2.log
  E2E_UNSTICK=0 E2E_CAP=28800 E2E_NOTE="GPU PINNED (AC drop #11 …) …" ./e2e-all.sh flashnext asm` (cap 8 h → ends by 00:16 at the latest;
  `last-start.env` → `.hold` again, **restore when the run is over**). The aborted 14:12 attempt is archived by the harness as
  `/data/ai/asm-task-flashnext.prev-20260915-161603` (+ `~/local-ai-runs/e2e-flashnext-asm.aborted-1535.log`). Telemetry pid file
  `~/local-ai-runs/telemetry.pid` (GUARD_PCH=108); watchdog PCH 98/104/106 + stop/resume hook live (a `PCH STOP` line in
  `/var/log/thermal.log` = service stopped at 106 °C, restarted when < 98 °C for 60 s, harness resumes within 1800 s).
  Progress: `tail -f ~/local-ai-runs/e2e-flashnext-asm.log`; `ls -la /data/ai/asm-task-flashnext`; `grep -c '"type"' …/qwen.log`;
  `sudo service llama-t2 status` (slot busy/idle); `sudo temp.sh` or `tail -3 ~/local-ai-runs/telemetry.csv`.
  Result goes to results-t2.md §3.5 (second part), report-t2.md, the T2 row above, ops.md §8.
- **Verified 16:13 (`--lazy-mode off`):** `procstat -v` shows **0 gguf mappings**, no "lazy" line in `llama-t2.out`,
  `vm.stats.vm.v_vnodepgsin` **+0** with the server up, wired **93.8 GiB** (experts + the 26.8 GiB PLE table + KV) — the model-file
  read stream is gone; the PCH sits at 67 °C in prefill.
- **Cold power-off cycle 16:06–16:09:** the GPU came back un-pinned (probe 16:09: 1905 MHz, 108 W, brake 0 µs) and the very first T2
  ramp step tripped the adapter again (`acpi_acad0: Off Line` 16:11:52–16:11:54, brake counter 88 s within a minute). The model load
  itself (87 GB from NVMe in ~45 s) pushed the PCH 66 → 87 °C — that is the hottest moment of a T2 start.

## Earlier today (16:00 snapshot, kept for the record)


- **Nothing.** The un-pinned `flashnext` asm attempt (14:12–15:35) was **aborted = FAIL-infra** (results-t2.md §3.5): two PCH runaways
  (guard kills 14:30 and 14:59) and then the 15:14 service restart's first ramp step tripped the adapter (`acpi_acad0: Off Line`
  15:14:49–15:14:56) → GPU pinned (brake counter 1069 s, prefill 135 → 44 t/s). Harness, qwen and `llama-t2` stopped 15:35 (server needed
  KILL after 30 s of TERM — third time today). Watchdog + telemetry run; the owner watches `sudo temp.sh -w 30`.
- **Measured before the abort (un-pinned):** re-prefill 82 077 tokens 607 s = **135 t/s** (GPU 80–116 W, SM up to 1860, CPU idle);
  decode **5.5–5.9 t/s** (1 725 tokens, cores 62–69 °C at 3.6–4.8 GHz) vs 3.3 pinned. → tier table T2 row.
- **Fixed since 14:15:** (1) the steady model-file page-fault stream = llama.cpp `--lazy-mode auto` mapping the 26.8 GiB
  `per_layer_token_embd.weight` (TENSOR_READ_LAZY) and fetching rows from NVMe per token — `--lazy-mode off` now in `llama-tier.sh`,
  `asgard/serve.sh`, `serve.sh` (both binaries accept it; +27 GiB RAM, table resident); (2) watchdog PCH policy 98/104/106 + stop/resume
  hook via `unstick.sh` (`service:tN` provenance) — ops.md §3; (3) datasets: `zroot/data/local-ai-models` (`/data/local-ai/models`,
  compression off, primarycache=metadata, recordsize 1M, atime off) and `zroot/data/local-ai-tmp` (`/data/local-ai/tmp`, lz4,
  sync=disabled) — ops.md §8.3; (4) `temp.sh` pin verdict (brake counter twice, duty %, no SM shortcut) — canonical copy now
  `asgard/temp.sh`, `/data/scripts/temp.sh` is a symlink to it, `~/asgard-cfg/thermal/temp.sh` (asgard + tuxi) synced.
- **Done 16:02–16:07 (operator):** `zroot/data/local-ai` folded into a plain directory on `zroot/data` (969 entries copied, owner/mode/mtime
  verified, git status unchanged; only `zroot/data/local-ai-models` and `zroot/data/local-ai-tmp` remain datasets); `~/local-ai-runs` →
  `/data/local-ai/tmp/runs` (2 607 entries, `diff -r` clean) with `~/local-ai-runs` a relative symlink (`../../data/local-ai/tmp/runs`, so it
  also resolves through tuxi's `/asgard` sshfs); `last-start.env` restored; `/etc/sysctl.conf` ARC comment refreshed (16 GiB kept);
  telemetry + pchwatch stopped (`pchwatch-20260915.log` kept in the runs dir); `/tmp/pfault.d`, probe logs removed. Owner's adapter re-plug
  15:54–15:55 did **not** clear the pin (probe 15:57). **16:06 `shutdown -p now`**, owner powered on 16:08 → see above.

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
- 13:58 owner started `service llama-t2` un-pinned (hello-world pp 78.7 / tg 4.9); 14:12 asm attempt un-pinned → **PCH runaway #1**
  14:19–14:30 (74 → 108 °C with the CPU capped 1200–2400 and cores 46–52 °C — CPU caps do not cool the PCH), guard kill 14:30:05;
  14:41 restart, resume 14:42:54; re-prefill 135 t/s; decode 5.5–5.9 t/s; **runaway #2** 14:56:58–14:59 (PCH and all four NVMe +14 °C
  together at constant load = an airflow step, on top of the fault IO), guard kill 14:59:18 — results-t2.md §3.5, ops.md §8.1–8.2.
- 14:35–15:19 thermal backup + watchdog PCH policy (98/104/106, stop/resume hook, `unstick.sh` learns `service:tN`) — ops.md §3.
- 15:00–15:14 datasets: models cloned (`cp` = BRT block clone, 1 s) onto `zroot/data/local-ai-models`, `local-ai` props inherited,
  `local-ai-tmp` created, `models.old` removed 15:20 (the free wrote 8 MB/s for 40 s → PCH 71 → 84: writes heat it too) — ops.md §8.3.
- 15:14 restart → adapter trip 15:14:49 → **pinned**; 15:22 dtrace: the fault stream is `llama-server` on `/data/local-ai/models`,
  root cause `--lazy-mode auto` × `per_layer_token_embd.weight` 26.8 GiB → `--lazy-mode off` everywhere (15:45–15:50) — ops.md §8.2.
- 15:29 operator mistake, useful anyway: a recursive grep read the model files at 750 MB/s for 30 s → PCH 73 → 93 °C in 30 s (killed;
  recovered in 1 min) = the cleanest proof that NVMe/DMI traffic heats the PCH within seconds.
- 15:40 `temp.sh` gpu_pin fixed + made canonical in the repo; 15:52 GPU compute-only probe (`test-backend-ops perf -b Vulkan0`):
  SW Power Cap active at 65 W, GPU 40–50 °C → the pin is a power-budget derating, not thermal (ops.md §8.4).


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

1. Operator: watch the asm run (see above) — PCH runaways (watchdog hook / guard), adapter events (`sudo grep acpi_acad0 /var/log/messages`),
   harness resumes. When it ends: `summary.txt` → results-t2.md §3.5 (second part: pinned, lazy off), report-t2.md, T2 row, ops.md §8.1;
   `mv ~/local-ai-runs/last-start.env.hold ~/local-ai-runs/last-start.env`; leave the service running for the owner (his call to stop it).
2. T0/T1 on `BIN_MASTER` (one build for all tiers): `bench.py`/`codebench.py` pp+tg vs the Sep-4 numbers, one E2E smoke each, then flip
   `BIN=$BIN_V2` → `$BIN_MASTER` in `llama-tier.sh`; keep `build-vulkan-2` until then. Only when the owner is not using a tier.
3. Owner, when convenient: BIOS Thermal Management **Ultra Performance** (the EC fan curve follows CPU/GPU only — the PCH ran away twice at
   cores 46–69 °C), read the AC adapter wattage (180 vs 240 W), Peak Shift / battery-assist options — all optional now that pinned is the regime.
4. Owner: `git add -A && git commit` in `/data/local-ai` (temp.sh, launchers, docs, .gitignore), `git pull` on tuxi.
5. Leftovers to delete when convenient: asgard `/tmp/bignum-*`, `/tmp/leakprobe*`, `/tmp/memleak*`, `/tmp/check_vectors.py`, `/tmp/*.bak*`
   (doc/sysctl backups from 15 Sep); VM `/tmp/t1`; optional `zfs set recordsize=128K zroot/data/local-ai-models` (cloned files keep 128K blocks).

## How to resume after a crash

- **State machine:** if `llama-t2` is not running and `/data/ai/asm-task-flashnext` has no `summary.txt`, the asm re-run has not happened yet —
  follow "Next" 3. If it is running: `tail ~/local-ai-runs/e2e-flashnext-asm.log`, `sudo service llama-t2 status`, `tail -3
  ~/local-ai-runs/telemetry.csv`, `sudo tail /var/log/thermal.log` (a `PCH STOP` line = the watchdog stopped the service at 106 °C and
  restarts it when the PCH is < 98 °C for 60 s; the harness resumes if `/health` is back within 1800 s, else the manual resume below).
- **Manual resume of a cut asm run:** server first (`sudo service llama-t2 start`, wait for UP), then `cd /data/local-ai/asgard && SID=$(grep -o
  '"session_id":"[0-9a-f-]*"' /data/ai/asm-task-flashnext/qwen.log | tail -1 | cut -d'"' -f4); RESUME=$SID LOG=~/local-ai-runs/llama-t2.log
  E2E_UNSTICK=0 E2E_CAP=28800 E2E_NOTE="GPU UN-PINNED, resumed" daemon -f -o ~/local-ai-runs/e2e-flashnext-asm-resume.log ./e2e-test.sh
  flashnext asm`; every cut costs a full re-prefill (82K tokens ≈ 10 min un-pinned, 30 min pinned). Afterwards `mv
  ~/local-ai-runs/last-start.env.hold ~/local-ai-runs/last-start.env`.
- After any asgard boot: `GUARD_PCH=108 daemon -f -p ~/local-ai-runs/telemetry.pid /data/local-ai/asgard/telemetry.sh
  ~/local-ai-runs/telemetry.csv` (telemetry does not survive a reboot; `~/local-ai-runs` is a symlink into `/data/local-ai/tmp/runs` after
  the 15 Sep fold); `sudo temp.sh` = pin verdict (`grep acpi_acad0 /var/log/messages` = drop count this boot). A tier service that was
  running when asgard died does **not** come back at boot (by design): `sudo service llama-tN start` again.
- **Never** start a model load "to check" right after a healthy boot if the goal is to keep the healthy regime (drops #6/#7/#9).
