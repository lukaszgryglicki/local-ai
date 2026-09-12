#!/bin/sh
# /data/local-ai/asgard/unstick.sh check|fix|watch [SEC]|kill|show|restart|pre-suspend|post-resume - repair a llama-server whose
# GPU work will never finish, and the thermal watchdog's suspend hooks.
# Background (2026-09-12 07:26, manual zzz with a request in flight): the box resumed fine and the process, /health and
# /slots stayed alive, but the main loop slept forever in ggml_vk_wait_for_fence -> libnvidia-eglcore poll() on a fence
# submitted before the suspend; GPU 0 % / 300 MHz, TERM ignored, the client (qwen-code) waiting silently. Fresh Vulkan
# contexts worked. Owner rules (2026-09-12 08:2x): a normal zzz / poweroff issued by the owner does NOTHING with llama
# (the owner stops/starts it); ONLY the thermal watchdog's suspend action stops the server first (a few seconds at
# most) and starts it again after the resume, only if it was running; its power-off action stops nothing.
# The server is found by its listening port (sockstat :18080), however it was started; a restart follows provenance:
#   start.sh   ~USER/local-ai-runs/llama.pid holds its pid (asgard/start.sh, also what llamactl.sh / service llama use)
#              -> start.sh --last as that user (replays ~USER/local-ai-runs/last-start.env)
#   relaunch   anything else (started by hand): exact argv, environment, cwd and binary are read from the kernel
#              (kern.proc.args/env sysctl, procstat) while it lives and it is relaunched identically as the same user
#              (launcher script kept in ~USER/local-ai-runs/unstick/relaunch-*.sh)
#   check         exit 0 = idle, working or no server; 2 = STUCK (slot processing and GPU 0 % for STUCK_AFTER (60) s of samples)
#   fix           check, and if stuck: diagnostics to ~USER/local-ai-runs/unstick/stuck-*.txt, kill -9, restart by provenance
#   watch [SEC]   loop: fix every SEC (30) s; asgard/e2e-test.sh runs this in the background during a task, so a server
#                 hung for whatever reason (incl. an owner's zzz mid-task) is replaced and the task's qwen session resumed
#   kill          no check: kill -9 + restart right away (when you know it is stuck)
#   show          who/how/where the server runs + write the identical-relaunch launcher (nothing is touched)
#   restart       stop the server (TERM, KILL after RESTART_GRACE (30) s) and start it again by provenance: start.sh --last
#                 for a start.sh server, identical relaunch for a hand-started one (llamactl.sh restart uses this)
#   pre-suspend   thermal-watchdog WD_SUSPEND_PRE (root): stop a running server (TERM, KILL after GRACE (3) s), remember
#                 how to bring it back in /var/run/llama-s3.state; no server -> nothing
#   post-resume   thermal-watchdog WD_SUSPEND_POST (root): if the state file says a server was running, start it again
#                 the same way; otherwise nothing
# Runs as root (watchdog hooks) or as the server's user (harness); user-owned files are always written as that user;
# events go to ~USER/local-ai-runs/unstick/unstick.log and syslog (logger -t unstick).
# check/fix never touch anything when there is no server, when the slot is idle or when the GPU is busy.
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
d=$(dirname "$(realpath "$0")"); PORT=${PORT:-18080}; u=http://10.253.254.1:$PORT; k=$(cat "$d/../key.secret" 2>/dev/null)
STUCK_AFTER=${STUCK_AFTER:-60}; GRACE=${GRACE:-3}; RESTART_GRACE=${RESTART_GRACE:-30}; STATE=/var/run/llama-s3.state; MODE=${1:-check}
server_pid() { sockstat -4l -p "$PORT" 2>/dev/null | awk 'NR>1 && $2 ~ /^llama/ {print $3; exit}'; }
processing() { curl -s -m 5 -H "Authorization: Bearer $k" "$u/slots" 2>/dev/null | grep -q '"is_processing":true'; }
gpu_busy() { [ "$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')" != 0 ]; }
now() { date '+%F %T'; }
as_user() { if [ "$(id -un)" = "$USER_" ]; then sh -c "$1"; else su -l "$USER_" -c "$1"; fi; }   # $1 = command string
logln() { printf '%s\n' "$*" | as_user "mkdir -p '$D' && tee -a '$D/unstick.log'"; logger -t unstick -- "$*" 2>/dev/null; }
check() {   # stuck = every 5 s sample over STUCK_AFTER s shows "slot processing and GPU 0 %"
  p=$(server_pid); [ -n "$p" ] || return 0
  n=0; while [ "$n" -lt $((STUCK_AFTER / 5)) ]; do processing || return 0; gpu_busy && return 0; n=$((n + 1)); sleep 5; done
  return 2
}
capture() {   # $1 = pid: sets USER_ HOME_ D RUNS HOW LAUNCHER LOGFILE CWD ts; writes the identical-relaunch script as the user
  USER_=$(ps -o user= -p "$1" | tr -d ' '); HOME_=$(eval echo "~$USER_"); ts=$(date +%Y%m%d-%H%M%S)
  D=$HOME_/local-ai-runs/unstick; LAUNCHER=$D/relaunch-$ts.sh
  eval "$(as_user "mkdir -p '$D' && python3 - '$1' '$LAUNCHER'" <<'EOF'
import ctypes, ctypes.util, shlex, subprocess, sys, time
libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
def strings(pid, what):   # KERN_PROC_ARGS = 7, KERN_PROC_ENV = 35 (sys/sysctl.h); NUL separated, exact
    mib = (ctypes.c_int * 4)(1, 14, what, pid); size = ctypes.c_size_t(0)
    if libc.sysctl(mib, 4, None, ctypes.byref(size), None, 0) != 0: raise OSError(ctypes.get_errno(), "sysctl")
    buf = ctypes.create_string_buffer(size.value)
    if libc.sysctl(mib, 4, buf, ctypes.byref(size), None, 0) != 0: raise OSError(ctypes.get_errno(), "sysctl")
    return [s.decode("utf-8", "surrogateescape") for s in buf.raw[:size.value].split(b"\0") if s]
def procstat(flag):
    return subprocess.run(["procstat", flag, str(pid)], capture_output=True, text=True).stdout.splitlines()[1:]
pid = int(sys.argv[1]); args = strings(pid, 7); env = strings(pid, 35)
cwd = [l.split()[-1] for l in procstat("-f") if l.split()[2:3] == ["cwd"]]; cwd = cwd[0] if cwd else "/"
binary = procstat("-b")[0].split()[3]
envd = dict(e.split("=", 1) for e in env if "=" in e)
log = args[args.index("--log-file") + 1] if "--log-file" in args else ""
import os
with open(os.open(sys.argv[2], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o700), "w") as f:
    f.write("#!/bin/sh\n# identical relaunch of llama-server pid %d captured %s by asgard/unstick.sh (argv, environment, cwd, binary from the kernel)\n" % (pid, time.strftime("%F %T")))
    f.write("cd %s || exit 1\nexec /usr/bin/env -i %s \\\n  %s\n" % (shlex.quote(cwd), " ".join(shlex.quote(e) for e in env), " ".join(shlex.quote(a) for a in [binary] + args[1:])))
print("CWD=%s; RUNS=%s; LOGFILE=%s" % (shlex.quote(cwd), shlex.quote(envd.get("LOCAL_AI_RUNS") or envd.get("HOME", "/nonexistent") + "/local-ai-runs"), shlex.quote(log)))
EOF
)"
  [ -n "${RUNS:-}" ] || RUNS=$HOME_/local-ai-runs
  if [ "$(cat "$RUNS/llama.pid" 2>/dev/null)" = "$1" ]; then HOW=start.sh; else HOW=relaunch; fi
}
terminate() {   # $1 = pid, $2 = seconds of grace after TERM before KILL; prints what happened
  kill -TERM "$1" 2>/dev/null; i=0
  while kill -0 "$1" 2>/dev/null && [ "$i" -lt $(($2 * 10)) ]; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$1" 2>/dev/null; then kill -9 "$1"; sleep 1; echo "KILL after $2 s"; else echo "TERM ok in $((i / 10)).$((i % 10)) s"; fi
}
bring_back() {   # uses HOW USER_ RUNS LAUNCHER D
  t0=$(date +%s)
  case $HOW in
    start.sh) out=$(as_user "rm -f '$RUNS/llama.pid'; LOCAL_AI_RUNS='$RUNS' '$d/start.sh' --last" 2>&1); rc=$?
              logln "$(now) start.sh --last as $USER_ (rc $rc): $(echo "$out" | grep -E 'UP in|EXITED|replaying|already' | tr '\n' ' ')"
              [ "$rc" = 0 ] || printf '%s\n' "$out" | as_user "tee -a '$D/unstick.log'" >/dev/null; return $rc ;;
    relaunch) as_user "daemon -f -p '$D/relaunch.pid' -o '${LAUNCHER%.sh}.out' sh '$LAUNCHER'"
              while :; do curl -s -m 2 "$u/health" 2>/dev/null | grep -q '"ok"' && break
                kill -0 "$(cat "$D/relaunch.pid" 2>/dev/null)" 2>/dev/null || { logln "$(now) relaunch EXITED - see ${LAUNCHER%.sh}.out"; return 1; }
                [ $(( $(date +%s) - t0 )) -ge 600 ] && { logln "$(now) relaunch: no /health after 600 s"; return 1; }; sleep 1; done
              logln "$(now) relaunched identically as $USER_: pid $(cat "$D/relaunch.pid"), UP in $(( $(date +%s) - t0 )) s, launcher $LAUNCHER" ;;
  esac
}
fix() {   # $1 = force: skip the check
  if [ "${1:-}" != force ]; then check && { echo "$(now) unstick: not stuck$( [ -n "$(server_pid)" ] || echo ' (no server)')"; return 0; }; fi
  p=$(server_pid); [ -n "$p" ] || { echo "$(now) unstick: no server listening on :$PORT"; return 0; }
  capture "$p"
  as_user "cat > '$D/stuck-$ts.txt'" <<EOF
$(now) llama-server pid $p (user $USER_, cwd $CWD, started via $HOW) STUCK: slot processing, GPU 0 % for $STUCK_AFTER s
$(uptime)
$(nvidia-smi --query-gpu=utilization.gpu,power.draw,memory.used,clocks.sm --format=csv,noheader)
$(curl -s -m 5 -H "Authorization: Bearer $k" "$u/slots" | cut -c1-300)
$(procstat -kk "$p" 2>/dev/null | awk 'NR>1{$1=$2="";print}' | sort | uniq -c | sort -rn | head -3)
$( [ -n "$LOGFILE" ] && tail -3 "$LOGFILE")
EOF
  logln "$(now) STUCK -> kill -9 $p, restart via $HOW (diagnostics $D/stuck-$ts.txt)"
  kill -9 "$p"; sleep 3
  bring_back
}
case $MODE in
  check) if check; then p=$(server_pid); if [ -n "$p" ]; then echo "ok: server pid $p (user $(ps -o user= -p "$p" | tr -d ' '))"; else echo "ok: no server on :$PORT"; fi; else echo "STUCK"; exit 2; fi ;;
  fix) fix ;;
  kill) fix force ;;
  watch) while :; do fix; sleep "${2:-30}"; done ;;
  show) p=$(server_pid); [ -n "$p" ] || { echo "no server on :$PORT"; exit 0; }; capture "$p"
        echo "llama-server pid $p, user $USER_, cwd $CWD, started via $HOW, log ${LOGFILE:-?}"
        echo "restart would be: $( [ "$HOW" = start.sh ] && echo "start.sh --last ($(tr '\n' ' ' < "$RUNS/last-start.env"))" || echo "identical relaunch")"
        echo "launcher: $LAUNCHER"; sed -n '3,$p' "$LAUNCHER" | tr -s ' ' | fold -w 160 | head -12 ;;
  restart)
    p=$(server_pid); [ -n "$p" ] || { echo "$(now) restart: no server on :$PORT"; exit 0; }
    capture "$p"; r=$(terminate "$p" "$RESTART_GRACE"); [ "$HOW" = start.sh ] && as_user "rm -f '$RUNS/llama.pid'"
    logln "$(now) restart: stopped llama-server pid $p ($USER_, via $HOW): $r - starting again via $HOW"
    bring_back ;;
  pre-suspend)
    [ "$(id -u)" = 0 ] || { echo "pre-suspend must run as root (thermal-watchdog WD_SUSPEND_PRE)"; exit 1; }
    p=$(server_pid); [ -n "$p" ] || { rm -f "$STATE"; echo "$(now) pre-suspend: no server"; exit 0; }
    capture "$p"
    printf "HOW='%s'\nUSER_='%s'\nRUNS='%s'\nLAUNCHER='%s'\nD='%s'\nPID='%s'\nWHEN='%s'\n" "$HOW" "$USER_" "$RUNS" "$LAUNCHER" "$D" "$p" "$(now)" > "$STATE"
    r=$(terminate "$p" "$GRACE"); [ "$HOW" = start.sh ] && as_user "rm -f '$RUNS/llama.pid'"
    logln "$(now) pre-suspend: stopped llama-server pid $p ($USER_, via $HOW): $r - restart on resume via $HOW" ;;
  post-resume)
    [ "$(id -u)" = 0 ] || { echo "post-resume must run as root (thermal-watchdog WD_SUSPEND_POST)"; exit 1; }
    [ -f "$STATE" ] || { echo "$(now) post-resume: no server was running before the suspend - nothing to do"; exit 0; }
    . "$STATE"; rm -f "$STATE"
    logln "$(now) post-resume: restarting llama-server via $HOW (stopped $WHEN before the suspend)"
    bring_back ;;
  *) sed -n '2,30p' "$0"; exit 1 ;;
esac
