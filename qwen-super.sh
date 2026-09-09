#!/bin/sh
# /data/local-ai/qwen-super.sh - crash-proof supervisor for headless qwen runs.
# Fixes the 2026-09-08 overnight failure: tunnel/network flapped -> qwen got
# ECONNREFUSED -> exited for good -> 5.5h of idle serving. tunnel.sh already
# auto-heals itself; this makes the CLIENT side survive too:
#   - waits until the model endpoint is healthy before every (re)launch,
#   - relaunches qwen after ANY crash/exit, with a resume-from-workspace prompt,
#   - stops only when the task itself touches DONE_FILE (or MAX_TRIES is hit).
#
#   usage: qwen-super.sh WORKSPACE PROMPT-FILE [LOGFILE]
#   knobs: MAX_TRIES=50, DONE_FILE=WORKSPACE/DONE,
#          HEALTH_URL=http://127.0.0.1:18081/health,
#          REMOTE_MODEL / COMPACT pass through to qwen-remote.sh
#   detached overnight run (FreeBSD - no setsid, use daemon):
#     daemon -o /dev/null /data/local-ai/qwen-super.sh \
#       ~/task/project ~/task/PROMPT.md ~/task/qwen.log
#
# Crash-safety rules are appended to every prompt: work in small increments
# (write files / git commit constantly - a crash loses anything not on disk)
# and touch DONE_FILE only when the whole task is complete.
ws=$1; pf=$2
[ -d "$ws" ] && [ -s "$pf" ] || { echo "usage: $0 WORKSPACE PROMPT-FILE [LOGFILE]"; exit 1; }
ws=$(realpath "$ws"); pf=$(realpath "$pf")
log=${3:-$ws/qwen.log}
d=$(dirname "$(realpath "$0")")
DONE_FILE=${DONE_FILE:-$ws/DONE}
HEALTH_URL=${HEALTH_URL:-http://127.0.0.1:18081/health}
MAX_TRIES=${MAX_TRIES:-50}
mark=$ws/.qwen-super-started
ts() { date -u +%H:%M:%SZ; }
sfx="

SUPERVISOR RULES (crash-safety - appended by qwen-super.sh):
- Your process can be killed at ANY moment (network outages happen) and will be
  restarted. Only what is ON DISK survives. Therefore: write every file as soon
  as it is drafted and git commit after every meaningful step. NEVER build up a
  long design or big code in one huge reply - persist it in small pieces first.
- Keep each reply short; put substance into files via tools, not into chat text.
- When and only when the WHOLE task is fully complete, run: touch $DONE_FILE"
try=0
while [ ! -f "$DONE_FILE" ] && [ "$try" -lt "$MAX_TRIES" ]; do
  try=$((try+1))
  n=0
  until curl -s -m 5 "$HEALTH_URL" 2>/dev/null | grep -q '"ok"'; do
    [ $((n % 10)) -eq 0 ] && echo "[$(ts)] super: endpoint down, waiting ($HEALTH_URL)" >> "$log"
    n=$((n+1)); sleep 30
  done
  if [ ! -e "$mark" ]; then
    p="$(cat "$pf")$sfx"
  else
    p="You are RESUMING an interrupted autonomous task (previous run was killed,
e.g. by a network outage). First re-read the full task: $pf
Then inspect the workspace (ls -laR, git log, STATUS/DEVLOG if present) to see
what is already done. Then continue from where it stopped, following all the
original rules.$sfx"
  fi
  : > "$mark"
  echo "[$(ts)] super: attempt $try/$MAX_TRIES launching qwen" >> "$log"
  ( cd "$ws" && QWEN_CODE_SUPPRESS_YOLO_WARNING=1 "$d/qwen-remote.sh" -y -p "$p" >> "$log" 2>&1 )
  rc=$?
  echo "[$(ts)] super: attempt $try exited rc=$rc" >> "$log"
  [ -f "$DONE_FILE" ] || sleep 15
done
if [ -f "$DONE_FILE" ]; then
  echo "[$(ts)] super: task COMPLETE (DONE found) after $try attempt(s)" >> "$log"
else
  echo "[$(ts)] super: GAVE UP after $MAX_TRIES attempts without DONE" >> "$log"
  exit 2
fi
