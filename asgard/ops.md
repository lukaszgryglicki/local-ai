# asgard operations — llama-server start/stop, the service, the thermal watchdog, suspend/resume, stall repair

Settled 2026-09-12 (owner rules 08:2x). This is the one document for "how is llama-server run on asgard and what
touches it automatically". Everything llama-side lives in this repo (`/data/local-ai`); the system only holds pointers.

## 0. The contract

1. **All POC/llama logic is in `/data/local-ai`** (`asgard/*.sh`, this file). System files (rc.d stub, rc.conf line,
   two watchdog-conf lines) only point here and are not expected to change again during the research phase.
2. **The owner starts and stops llama-server.** A normal `zzz` (`z`), lid close, reboot or poweroff issued by the owner
   does nothing with llama. (Mind §4: a server with a request in flight does not survive S3 — stop it first, or let the
   E2E stall detector replace it afterwards.) During an E2E task the harness keeps its server alive: a hung one is
   replaced (`unstick.sh watch`), a crashed one is started again (`start.sh --last`) — outside a task, nothing is.
3. **Only the thermal watchdog's *suspend* action touches it automatically**: right before its S3 request it stops
   the server (TERM, KILL after 3 s, hard limit 15 s) and remembers that it was running; after the resume it starts it
   again the same way — only if it was running. The watchdog's *power-off* action stops nothing (no waiting).
4. **The service is never in the boot sequence** while we research (`KEYWORD: nostart`). `/usr/local/etc/rc.d/llama`
   is a stub whose four commands call `asgard/llamactl.sh`; that script is the service.

- **Driver limit (measured 12 Sep):** the NVIDIA FreeBSD driver (595.99.02) fails single host-visible (pinned) Vulkan
  allocations ≥ 256 MiB — all of them without `VK_EXT_memory_priority`, and with it (ggml's case) those in the windows
  [256, 265), [512, 522), [1024, 1035), [2048, ≈2062) MiB, depending on the process' allocation history; < 256 MiB is
  always fine. An unpatched llama-server aborts when ggml reads or writes one tensor slice that large in one go (context
  checkpoints of a ≥ 128K-token f16 draft KV, `--cache-ram` slot saves of huge contexts, …). `serve.sh` therefore runs
  the patched `build-vulkan-2` (chunked ≤ 64 MiB staging transfers, `patches/0001`) by default; `build-vulkan` is the
  unpatched fallback (`B=`), and `DRAFT_KV=q8_0` stays the default.

## 1. What lives where

| file | role |
|---|---|
| `asgard/models.sh` | per-model file, spec-type, cache-ram, sampling, thinking toggle (`north`, `qwen9b`, `gemma`, `qwen35b`) |
| `asgard/serve.sh MODEL` | `exec llama-server` with all knobs (`NP`, `CTX`, `THREADS`, `THREADS_BATCH`, `NCMOE`, `SPEC`, `EXTRA`, `IGPU_MOE`, `DEV`, `VKVIS`); header = the pinned-cap rules |
| `asgard/start.sh MODEL` / `--last` | `daemon -f -p ~/local-ai-runs/llama.pid serve.sh`, waits for `/health`, rotates `llama.log` → `.prev`, records every start in `~/local-ai-runs/last-start.env`; `--last` replays it |
| `asgard/stop.sh` | TERM the pidfile's server, KILL after 30 s, prints VRAM after |
| `asgard/llamactl.sh start [MODEL] \| stop \| restart [MODEL] \| status` | **the service**: `start` = `start.sh MODEL`, or without MODEL a replay of the last start (`DEFAULT_MODEL` if none ever); `status` = pid + what was started + `/health`, `/props`, `/slots` (metadata only). Runs as `lgryglicki`; as root it re-executes itself via `su -l` |
| `asgard/rc.d/llama` | source of the stub `/usr/local/etc/rc.d/llama` (`install -m 555`) |
| `asgard/unstick.sh` | stall detector + the two watchdog hooks (§3, §5) |
| `asgard/zzz-probe.sh` | the S3 probe used in the live test (`state \| ref \| cmp \| pre \| task \| zzz \| post`) |
| `asgard/e2e-test.sh`, `e2e-all.sh`, `e2e-tasks.sh`, `verify-*.sh`, `sweep.sh`, `telemetry.sh` | the test harness (`results-t1.md`); `e2e-test.sh` runs `unstick.sh watch 30` alongside every task and resumes its qwen session after an API error |
| `asgard/health.sh` | **sends a real completion** ("Reply with exactly: OK") — only on an idle server; with NP=1 it queues behind a running task and then evicts its KV cache |

System side (asgard):

| file | content | why |
|---|---|---|
| `/usr/local/etc/rc.d/llama` | stub, `KEYWORD: nostart`, `start_cmd`/`stop_cmd`/`restart_cmd`/`status_cmd` = `/data/local-ai/asgard/llamactl.sh …` | `sudo service llama start\|stop\|restart\|status`; never at boot, nothing at shutdown/suspend/resume |
| `/etc/rc.conf` | `llama_enable="YES"` | only unlocks the plain commands (`onestart` & co. work regardless); `nostart` keeps it out of the boot order |
| `/usr/local/etc/thermal-policy.conf` | `WD_ACTION="suspend"`, `WD_SUSPEND_PRE="/data/local-ai/asgard/unstick.sh pre-suspend"`, `WD_SUSPEND_POST="/data/local-ai/asgard/unstick.sh post-resume"` | the only automatic path (§3) |
| `/usr/local/sbin/thermal-watchdog` (+ `rc.d/thermal_watchdog`, `thermal-policy`) | generic: runs `WD_SUSPEND_PRE` under `timeout 15` right before `acpiconf -s 3`, `WD_SUSPEND_POST` backgrounded after the resume; no hook for a power-off action | knows nothing about llama |
| copies/backups | `~/asgard-cfg/thermal/` on asgard and on tuxi (`thermal-watchdog`, `thermal-policy.conf`, `*.bak-<date>`) | system files are not in this repo |

Runtime files: `~/local-ai-runs/llama.pid`, `last-start.env`, `llama.log` (+ `.prev`), `unstick/unstick.log`,
`unstick/relaunch-*.sh` (mode 700, identical-relaunch launchers), `unstick/stuck-*.txt` (diagnostics);
`/var/run/llama-s3.state` (root, exists only between a watchdog pre-suspend and its post-resume); `/var/log/thermal.log`;
syslog tags `unstick` and `thermal-watchdog`. Nothing under `/var/tmp` (1 GiB tmpfs, wiped at boot).

## 2. Day-to-day commands

```sh
cd /data/local-ai/asgard
NP=1 ./start.sh qwen9b            # by hand, with knobs (see serve.sh header); prints UP time, VRAM, KV/compute lines
./stop.sh                          # TERM, KILL after 30 s
./llamactl.sh status               # or: sudo service llama status
sudo service llama start           # replay the last start (whoever made it) — first ever: DEFAULT_MODEL in llamactl.sh
sudo service llama start gemma     # that model with its defaults (NP=1, ctx 262144, models.sh spec/cache-ram); no MODEL = last start or qwen35b (T-1 winner)
sudo service llama restart         # stop + the same config again
sudo service llama stop
./unstick.sh show                  # who/how/where the server runs, what a restart would do
```

Knobs travel only through the environment of the user's shell (`sudo`/`su -l` drop them): start by hand with knobs,
then `service llama restart` replays them (`last-start.env`). Never two servers: `start.sh` refuses when the pidfile is
alive. **A server started without `start.sh`** (plain `daemon -f ./serve.sh …`, no pidfile) **is found by its port**
(`sockstat :18080`) by everything: `service llama status` reports it ("started by hand, no pidfile" + its argv),
`stop` stops it, `restart` relaunches it *identically* (argv/env/cwd/binary read from the kernel, `unstick.sh restart`),
and the watchdog hooks handle it the same way (verified 11:43, §6). `start` with a hand-started server running says
"already running" and does nothing. The one thing a hand-started server lacks is `last-start.env`, so a later
`service llama start` (after a `stop`) replays the last *`start.sh`* configuration, not the hand-started one.

## 3. The thermal watchdog and llama — the only automatic path

At CRITICAL (core ≥ 98 °C for 3 ticks, NVMe ≥ 87 °C for 2, PCH ≥ 115 °C) with `WD_ACTION="suspend"`:

1. EVENT line in `/var/log/thermal.log`, syslog `daemon.crit`, `wall`; CPU cap to 1.2 GHz.
2. `timeout 15 sh -c "unstick.sh pre-suspend"` (root): server found by `sockstat :18080`; provenance captured
   (`start.sh` if `~/local-ai-runs/llama.pid` holds its pid, otherwise an identical-relaunch launcher from the kernel's
   argv/env/cwd/binary); state written to `/var/run/llama-s3.state`; TERM, KILL after 3 s; pidfile removed. No server →
   nothing, state file removed. Typical cost 1–2 s; a hook that misbehaves is cut at 15 s and S3 proceeds.
3. Escalation helper armed: after `WD_SUSPEND_GRACE` = 20 s of *run time* a still-critical sensor powers the box off.
4. `acpiconf -s 3`. The owner resumes with the power button.
5. Watchdog logs "back from the suspend request", resets counters, keeps the cap, and runs
   `unstick.sh post-resume` in the background: state file present → `start.sh --last` as the user (or the launcher
   via `daemon`), waits for `/health`, logs "UP in N s"; no state file → "nothing to do".
6. A running E2E task saw an API error meanwhile; `e2e-test.sh` waits for `/health` and continues the same qwen
   session (`qwen -r SID`); the deep context is re-ingested (`--cache-ram 0`: ~7 min for 128K).

With `WD_ACTION="/sbin/shutdown -p now"` nothing is stopped first — the power-off is immediate.

Verified: mock run 08:16 (acpiconf/shutdown/wall/logger/set_ratio stubbed, thresholds forced) — order `CRITICAL →
pre-hook → acpiconf → back → post-hook`; a 40 s pre-hook cut at 15 s (`failed (124)`) with S3 still proceeding; a
power-off action running no hook. Real stop/start cycle of the hooks on the live server: §6.

## 4. Why — the S3 live test (2026-09-12 07:26)

`sudo zzz` with qwen9b mid-generation (C task, ctx ≈ 129K), resumed after 93 s: process, `/health`, `/slots` alive,
VRAM held, but the main loop asleep forever in `ggml_vk_wait_for_fence → libnvidia-eglcore poll()` on a fence
submitted before the suspend; GPU 0 % / 300 MHz; SIGTERM ignored (KILL frees the VRAM); the 595.99.02 driver reports
no device loss; fresh Vulkan contexts work; the client waits silently. Full record, lldb chain and consequences:
`results-t1.md` → "S3 live test 07:26". Whether an *idle* server's VRAM survives S3 was not tested (`zzz-probe.sh
pre / zzz / post` would tell); by the contract above it is the owner's call to stop before a manual `zzz`.

## 5. The stall detector (`unstick.sh`)

`check` (exit 2 = STUCK), `fix`, `watch [SEC]`, `kill`, `show`, plus the hooks `pre-suspend` / `post-resume` (root).
Stuck = the slot reports `is_processing` **and** `nvidia-smi` utilisation is 0 for 60 s of 5-s samples (a working
server never idles the GPU that long; a loading or idle server is never touched). Then: diagnostics
(`uptime`, GPU state, `/slots`, `procstat -kk` top frames, log tail) to `~/local-ai-runs/unstick/stuck-<ts>.txt`,
`kill -9`, restart by provenance, one line in `unstick.log` + syslog. It runs as the user during every E2E task
(`e2e-test.sh`: `watch 30`), so a server hung for whatever reason mid-task — including an owner's `zzz` — is replaced
and the task resumed. By hand after such a `zzz`: `./unstick.sh kill` (or `./stop.sh`, which escalates to KILL after
30 s, then `./start.sh …`).

## 6. Verification log

| when | what | result |
|---|---|---|
| 08:01 | `unstick.sh check` / `show` as user and as root (live server pid 38939) | ok; provenance `start.sh`; launcher written as the user, mode 700, env/argv/cwd/binary exact |
| 08:03 | `service llama status` first version (called `health.sh`) | **caught**: a completion queued behind the C task (server `cancel task 2870` after the client was killed, task unharmed) → status/health are metadata-only since |
| 08:05–08:18 | stub rc.d + `llamactl.sh status` as root and as user; `rcorder` lists | works; `llama` absent from boot (`-s nostart`), suspend and shutdown orders; `llama_s3` (interim devd hook) removed |
| 08:16 | watchdog mock (3 variants, §3) | as specified |
| 08:18 | `unstick.sh post-resume` with no state file (root) | "no server was running before the suspend - nothing to do" |
| 11:41 | **live hook cycle, `start.sh` server** (pid 38939, idle): `sudo unstick.sh pre-suspend` → `post-resume` | pre: TERM ok in 2.9 s, state file written, pidfile removed; post: `start.sh --last` replayed `qwen9b NP=1`, UP in 6 s (pid 81235), state file gone. Bug found+fixed: `WHEN=<date time>` was unquoted in the state file → `. state` failed on the time ("11:41:50: not found"), now every value is single-quoted |
| 11:42 | **live hook cycle, hand-started server** (`NP=1 daemon -f ./serve.sh qwen9b`, no pidfile) → `show` → `pre-suspend` → `post-resume` | `show`: provenance `relaunch`, launcher written; pre: TERM ok; post: relaunched identically as lgryglicki, UP in 6 s — 72/72 argv tokens identical, same env keys, cwd `/data/local-ai/asgard`, still no pidfile (provenance preserved) |
| 11:44 | `service llama status` / `stop` with the hand-started server | **caught**: status said "not running" next to `health: ok`, `stop` said "no pidfile" and left it running → `stop.sh`, `llamactl.sh` now fall back to the port owner (`sockstat`), `unstick.sh restart` added, `llamactl.sh restart` uses it for hand-started servers |
| 11:45 | `service llama status` → `restart` → `stop` → `status`, hand-started server | status: "started by hand, no pidfile" + argv; restart: identical relaunch, TERM 2.1 s, UP in 6 s (8.4 s total); stop: "stopped pid … listening on :18080 (started by hand)", VRAM 0; status: "not running (no live pid …, nothing listening on :18080)" |
| 11:46 | `service llama start` (no MODEL) → `start` again → `restart` → `unstick.sh check`, `start.sh` provenance | start: replayed `qwen9b NP=1`, UP in 6 s; second start: "already running: pid … via start.sh"; restart: stop.sh + replay, 9.1 s total, pidfile updated; check: ok |
| 12:21 | **llama-server SIGABRT mid-task** (qwen9b asm, ~99K ctx) — not stuck, not thermal | abort text lost (no `daemon -o`, `kern.coredump=0`) → `start.sh` now logs stderr to `~/local-ai-runs/serve.out` and archives old logs in `~/local-ai-runs/logs/`; nobody restarted it (by design: only hung servers were replaced) → `e2e-test.sh` now restarts a vanished server once per resume via `start.sh --last`, task-time only; hand restart 12:34:20, session resumed by the harness 12:34:29 |
| 12:43 | **second SIGABRT** 9 min after the restart, first request after a 130K re-encode — `serve.out` caught it: `vk::Device::allocateMemory: ErrorOutOfDeviceMemory`, `Memory allocation of size 269924352 failed`, in `create_checkpoint` → `update_dft` → `state_seq_get_data` (Vulkan staging buffer for a 131 799-token f16 draft-KV slice) | root cause proven with a Vulkan probe: the NVIDIA FreeBSD driver rejects any **single host-visible allocation ≥ 256 MiB** (255 ok, total unlimited); no runtime knob exists (device-buffer knobs only, upstream master unchunked). Hand restart 13:06:2x `NP=1 GGML_VK_ALLOW_SYSMEM_FALLBACK=1 ./start.sh qwen9b`, harness resumed 13:06:28 (downtime 1 381 s, excluded). Flag is not on that code path, so its "success" is coincidence; kept only for this run |
| 13:10 | `serve.sh`: `DRAFT_KV=q8_0` default (`--spec-draft-type-k/-v`, 1 088 B/token → cap ≈ 247K tokens; `q4_0` clears 262K); `start.sh --last` persists `DRAFT_KV` and `GGML_VK_ALLOW_SYSMEM_FALLBACK` | takes effect at the next server start (pid 87550 still runs f16 draft KV) |
| 13:40 | `patches/0001-vulkan-chunk-staging-transfers.patch` (chunked `ggml_vk_buffer_read/_write`, ≤ 64 MiB pieces, `GGML_VK_STAGING_CHUNK_MB`) applied to `/data/ai/local-agent-poc/src/llama.cpp` (working tree, not built); `build-vulkan-2.sh` builds it into `build-vulkan-2/` | build + validation (`GGML_VULKAN_MEMORY_DEBUG=1`, > 131K-token checkpoint scenario, f16 draft KV, flag unset) only when no E2E task runs; then `serve.sh B=` → `build-vulkan-2/bin`, keep `build-vulkan` as fallback |
| 14:18 | `build-vulkan-2.sh` finished (31 min, ggml-vulkan.cpp starved by the verify server for ~20 min; `NICE=19 J=6`) | `build-vulkan-2/bin/llama-server` + `libggml-vulkan.so` with the patch (RUNPATH → own bin dir; `build-vulkan/` untouched) |
| 14:22 | `verify-staging.sh new f16` with chunking *off* (`GGML_VK_STAGING_CHUNK_MB=100000`, `-lv 5`, staging log on) — the diagnostic | staging grew 98 304 → … → 279 715 840 B, every ≥ 256 MiB allocation *succeeded* → the 12:43 failure is not a fixed cap; probes `pin2..pin5` then showed the priority-dependent 2^n windows + history dependence (results-t1.md) |
| 14:40 | `EXTRA="-lv 5" verify-staging.sh new f16` (default 64 MiB chunking, 136 554-token prompt + follow-up; checkpoints at 132 161 / 135 526 / 136 534 / 136 550 tokens = 258–267 MiB f16 K slices) | **PASS**: staging capped at 67 108 864 B, both answers, server alive, 0 crash lines (`vt/staging-new-f16-144039.out`) |
| 14:48 | `verify-staging.sh new q8_0` (the serve.sh default draft KV) | **PASS**: same, 471 s + 1.3 s; q8_0 draft KV works with Vulkan flash-attn (`vt/staging-new-q8_0-144842.out`) |
| 14:40 | `serve.sh` default `B=` → `build-vulkan-2` (deployed via `.new` + `mv`; `build-vulkan` stays as fallback) | first used by the next server start (gemma) |
| 14:58–16:33 | gemma: fit ladder (NP 4/3/2 fail, **NP=1 14 545 MiB**), sweep `ngram-mod` vs `none` (48.5 vs 48.3 t/s cold, a wash), E2E all four with `ngram-mod` | rust PASS, go 46/47, c FAIL, asm FAIL (never ran the assembler) = **1/4**; first full run on the patched build, ctx to 141.8K, 0 restarts |
| 16:37–21:43 | qwen35b: fit (NP=2 fails, **NP=1 14 099 MiB**), sweep (`none` **58.7** vs `ngram-mod` 50.3 t/s aggregate, +17 %), E2E all four with `SPEC=none` | rust PASS 110 s, go PASS 256 s, c near-miss (420/420 arithmetic), asm FAIL at the 4-h cap = **2/4**; 5 h 20 min serving, ctx to 234.6K (two compactions), `--cache-ram 8192`, 0 restarts, 0 FAIL-infra |
| 21:46 | **T-1 frozen**: `models.sh` qwen35b `MODEL_SPEC=none`; default model `qwen35b` in `start.sh`, `serve.sh`, `qwen.sh`, `llamactl.sh` (`DEFAULT_MODEL`); bare `./start.sh` verified (UP in 5 s, 14 099 MiB, `--spec-type none`), then `stop.sh` | `sudo service llama start` = the `fastest-vram` profile from now on; results-t1.md §5 |
| 22:00 | T0 start: models.sh gains `qwen35b-q4`, `kat-q4`, `qwen35b-q8` (+ `MODEL_IGPU_MOE` per model, honoured by serve.sh); serve.sh `IGPU_MOE` path fixed (`--split-mode layer --tensor-split 1,0`; `none` prunes the device list → abort at load); placement sweep on the IQ2_M file: 20 expert layers in CPU RAM 30.4 t/s vs on the iGPU 14.5 t/s (pp 103 vs 6 t/s) | overflow goes to CPU RAM; results-t0.md §1; download queue `~/local-ai-runs/dl-t0-queue.sh` running |
| 22:36–22:52 | `qwen35b-q4` downloaded + sha256 OK; fit ladder k=14/16 fail, **k=18 UP-but-OOM at first decode**, **k=20 = 15 144 MiB**; sweep `none` **30.7 t/s** agg (pp 83–90), `ngram-mod` 28.2 | `MODEL_NCMOE=20` confirmed; "UP is not fit" rule; results-t0.md §2 |
| 22:50–23:10 | two-device (Quadro+P630) load failure root-caused: one failed pinned `vkAllocateMemory` (515 MiB `token_embd` right after the big Intel allocation) poisons every later NVIDIA allocation in the process; work-around `--override-tensor token_embd.weight=Vulkan0`; true-iGPU Q4 sweep **16.2 t/s / pp 6** → `IGPU_MOE` retired; `sweep.sh` multi-word `EXTRA` quoting fixed | results-t0.md §1; CPU RAM is the T0/T1 overflow target, final |
| **23:10:41** | **`acpi_acad0: Off Line` — AC power lost** (physical; the only AC event since the 05:55 boot). Unnoticed until 23:41: box runs on, Quadro capped at P2/1 035 MHz ("Idle" reason), frozen T-1 config 16.2 instead of 61.3 t/s, `qwen35b-q4` 6.7 instead of 30.7 t/s; every measurement 23:11–23:41 invalid (depth bench, EPP, `--no-host`, controls) | **FAIL-infra**, nothing charged to a model; results-t0.md §3 |
| 23:42–23:46 | server stopped, Q8 download paused at 13.97/36.9 GB (`.part` resumes), backlight 10 %, EPP back to 100, **`battery-guard.sh`** (root `daemon`, log `~/local-ai-runs/battery-guard.log`): exits when AC returns, clean `shutdown -p now` at ≤ 5 % / ≤ 5 min. Battery 51 %, ~33 W idle draw, ~65 min | **waiting for AC**; no GPU work until then; thermal-watchdog patched (`ac=` field + AC-transition events; live after the next `service thermal_watchdog restart`) |
| **00:01:31** | **`acpi_acad0: On Line` — AC back** (battery 41 %, charging ~38 W); battery guard exited by itself, backlight 60 | **FAIL-infra closed** — but the Quadro stays at **base clock 1035 MHz** (P2/P3, `Idle` reason, 16 t/s instead of 61 on the all-VRAM control): nvidia-smi `-lgc` ignored; no thermal/power/HW-brake reason; CPU not throttled (4.4 GHz seen) |
| 00:05–00:24 | root cause hunt: RM ioctl tool **`nvpowersrc.c`** (`~/local-ai-runs/nvpowersrc`, non-privileged `NV2080_CTRL_CMD_PERF_{GET,SET}_POWERSTATE` / `SET_AUX_POWER_STATE` / `RATED_TDP_*`) shows the driver believes **`battery`** while `hw.acpi.acline=1` and re-reads it on every first-client attach (battery `_BST` state 2 = charging suspected); setting AC restores the memory clock (5000 → 6801 MHz) but the SM stays at 1035 → a second, platform-level (Dell EC/SBIOS) limiter | **`gpu-cap-watch.sh`** (user `daemon`, `~/local-ai-runs/gpu-cap-watch.log`) polls every 10 min and exits when tg ≥ 50 t/s; all speed numbers since 23:10 invalid; download queue resumed 00:07 |
| 00:26–00:30 | **T-1 frozen for good**: `qwen35b` only — North / qwen9b / gemma GGUFs deleted (32.8 GB), entries removed from `models.sh`, defaults/examples in `serve.sh qwen.sh llamactl.sh e2e-*.sh download.sh sweep.sh zzz-probe.sh rust-test.sh verify-staging.sh readme.md plan.md` updated; `kat-q4` fit ladder (clock-independent): k=18 15 654 MiB, **k=19 15 223 → 15 267 MiB after the first request (OK)**, k=20 14 725, k=22 13 863 | T0 continues: KAT `MODEL_NCMOE=19`; Q8 fit when the download completes; E2E only once the GPU boosts again |
| 00:45–00:52 | Q8 download: the 00:10 curl ended with a short body at 32.4/36.9 GB (`VERIFY_FAIL` on the `.part`, queue exited); `download.sh qwen35b-q8` resumed it (`--continue-at -`), `VERIFIED_OK` 00:52 | Q8 present; the queue's `.part` verify is a feature, not a bug — re-run `download.sh` | results-t0.md §5 |
| 00:53–01:05 | **FAIL-infra #2, fixed**: `fit.sh qwen35b-q8` died at every k — 24× `Failed to allocate pinned memory` then the poisoned KV alloc. `top`: 92 GiB wired, 30 GiB free, **ARC 88 GiB** (`c_max` unlimited; `primarycache=all` since 11 Sep + 37 GB of downloads). Fix: `sysctl vfs.zfs.arc.max=16 GiB` (+ `/etc/sysctl.conf`), `sysctl debug.uma_reclaim=2` (wired 92 → 15 GiB, free 106 GiB), `zfs set primarycache=metadata zroot/data/local-ai` (back to the readme recipe). Re-run: 0 warnings; **Q8 k=27 fails (compute buffer), k=29 = 15 011 → 15 064 MiB after a 4K request (chosen), k=31 13 382, k=33 11 752** | `models.sh qwen35b-q8 MODEL_NCMOE=29` confirmed; likely also explains the T-1 `qwen9b` 256 MiB pinned failures (FAIL-infra); rule: check `top` Wired before fits | results-t0.md §3.2, §5.1 |
| 01:07 | battery **full** (100 %, state 0) — GPU still pinned (16.3 t/s, RM `battery`) | full-charge hypothesis refuted | results-t0.md §3.1.1 |
| 01:10–01:20 | **GPU pin root cause closed**: FreeBSD `nvidia.ko` 595.99.02 glue (`src/nvidia/nvidia_acpi.c` of the driver tarball) stubs `nv_acpi_get_powersource`, `nv_acpi_method` (`_DSM`), `nv_acpi_methods_init` and never calls `rm_power_source_change_event`/`rm_acpi_notify`; `osinit.c:2383` only forwards an OS power source if that call succeeds → the RM sees only the GPU's hardware AC/DC line from the Dell EC, which has said DC since 23:10:41 (DSDT: `_PSR` = `ECG2()` is a separate EC bit; the D-notifier path via EC reg 0x2E/`EVD2`/`HGPS` is dead without `_DSM`). No software fix; owner: AC replug, else reboot. Under the pin: qwen35b-q4 11.5 t/s, Q8 7.3–8.0, all-VRAM 16.3 → **no E2E started tonight**; watch loop back on 01:19; ACPI dump kept at `~/local-ai-runs/acpi/asgard-acpi-595.dsl` | investigation complete; T0 waits for the owner's replug | results-t0.md §3.1.1 |

## 7. At the real end (when the research phase is over)

- Boot start: remove `nostart` from the `KEYWORD` line of `asgard/rc.d/llama`, reinstall the stub
  (`sudo install -m 555 asgard/rc.d/llama /usr/local/etc/rc.d/llama`); set `DEFAULT_MODEL` in `llamactl.sh`
  (or rely on `last-start.env`). Consider `KEYWORD: shutdown` for a clean stop at shutdown.
- Decide whether a manual `zzz` should stop/restart llama too (the devd path `/etc/rc.suspend` / `rc.resume` with an
  rc.d script carrying `KEYWORD: suspend resume` was built and removed on 2026-09-12 — `unstick.sh pre-suspend` /
  `post-resume` are reusable as-is; note rc.subr only runs such hooks for an *enabled* rcvar).
- `health.sh` could get a `--no-completion` mode; until then `llamactl.sh status` is the safe probe.
