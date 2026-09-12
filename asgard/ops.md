# asgard operations — llama-server start/stop, the service, the thermal watchdog, suspend/resume, stall repair

Settled 2026-09-12 (owner rules 08:2x). This is the one document for "how is llama-server run on asgard and what
touches it automatically". Everything llama-side lives in this repo (`/data/local-ai`); the system only holds pointers.

## 0. The contract

1. **All POC/llama logic is in `/data/local-ai`** (`asgard/*.sh`, this file). System files (rc.d stub, rc.conf line,
   two watchdog-conf lines) only point here and are not expected to change again during the research phase.
2. **The owner starts and stops llama-server.** A normal `zzz` (`z`), lid close, reboot or poweroff issued by the owner
   does nothing with llama. (Mind §4: a server with a request in flight does not survive S3 — stop it first, or let the
   E2E stall detector replace it afterwards.)
3. **Only the thermal watchdog's *suspend* action touches it automatically**: right before its S3 request it stops
   the server (TERM, KILL after 3 s, hard limit 15 s) and remembers that it was running; after the resume it starts it
   again the same way — only if it was running. The watchdog's *power-off* action stops nothing (no waiting).
4. **The service is never in the boot sequence** while we research (`KEYWORD: nostart`). `/usr/local/etc/rc.d/llama`
   is a stub whose four commands call `asgard/llamactl.sh`; that script is the service.

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
sudo service llama start gemma     # that model with its defaults (NP=1, ctx 262144, models.sh spec/cache-ram)
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

## 7. At the real end (when the research phase is over)

- Boot start: remove `nostart` from the `KEYWORD` line of `asgard/rc.d/llama`, reinstall the stub
  (`sudo install -m 555 asgard/rc.d/llama /usr/local/etc/rc.d/llama`); set `DEFAULT_MODEL` in `llamactl.sh`
  (or rely on `last-start.env`). Consider `KEYWORD: shutdown` for a clean stop at shutdown.
- Decide whether a manual `zzz` should stop/restart llama too (the devd path `/etc/rc.suspend` / `rc.resume` with an
  rc.d script carrying `KEYWORD: suspend resume` was built and removed on 2026-09-12 — `unstick.sh pre-suspend` /
  `post-resume` are reusable as-is; note rc.subr only runs such hooks for an *enabled* rcvar).
- `health.sh` could get a `--no-completion` mode; until then `llamactl.sh status` is the safe probe.
