#!/bin/sh
# /data/local-ai/qwen-super.sh - crash-proof supervisor for headless qwen runs.
# Fixes the 2026-09-08 overnight failure: tunnel/network flapped -> qwen got
# ECONNREFUSED -> exited for good -> 5.5h of idle serving.
#
# Three defense layers (inner to outer):
#   1. qwen-remote.sh sets maxRetries=5000: the openai SDK itself retries
#      connection errors/429/5xx (backoff capped ~8s) for ~11h -> a dropped
#      tunnel BETWEEN requests no longer kills the turn.
#   2. A drop MID-STREAM still fails the process -> this supervisor relaunches
#      it with `qwen -c` = REAL session resume (chat recording is on by
#      default): the model gets its full previous conversation back, like
#      `claude --resume` / `copilot --resume`.
#   3. If no recorded session exists (first run / recording disabled), it
#      falls back to a resume-from-workspace-state prompt.
#
#   usage: qwen-super.sh WORKSPACE PROMPT-FILE [LOGFILE]
#   knobs: MAX_TRIES=50, DONE_FILE=WORKSPACE/DONE,
#          HEALTH_URL=http://127.0.0.1:18081/health,
#          REMOTE_MODEL / COMPACT pass through to qwen-remote.sh
#   detached overnight run (FreeBSD - no setsid, use daemon):
#     daemon -o /dev/null /data/local-ai/qwen-super.sh \
#       ~/task/project ~/task/PROMPT.md ~/task/qwen.log
#
# Crash-safety rules are appended to the initial prompt: work in small
# increments (write files / git commit constantly - only disk + the recorded
# session survive a crash) and touch DONE_FILE only when fully complete.
ws=$1; pf=$2
[ -d "$ws" ] && [ -s "$pf" ] || { echo "usage: $0 WORKSPACE PROMPT-FILE [LOGFILE]"; exit 1; }
ws=$(realpath "$ws"); pf=$(realpath "$pf")
log=${3:-$ws/qwen.log}
d=$(dirname "$(realpath "$0")")
qhome=/tmp/remote-ai-qwen-home   # must match h= in qwen-remote.sh
DONE_FILE=${DONE_FILE:-$ws/DONE}
HEALTH_URL=${HEALTH_URL:-http://127.0.0.1:18081/health}
MAX_TRIES=${MAX_TRIES:-50}
ts() { date -u +%H:%M:%SZ; }
has_session() {
  # chats live under .qwen/projects/<cwd-with-dashes>/chats/*.jsonl
  pdir=$(printf '%s' "$ws" | tr '/' '-')
  set -- "$qhome/.qwen/projects/$pdir/chats/"*.jsonl
  [ -s "$1" ]
}
sfx="

SUPERVISOR RULES (crash-safety - appended by qwen-super.sh):
- Your process can be killed at ANY moment (network outages happen); it will be
  resumed. Persist relentlessly anyway: write every file as soon as it is
  drafted and git commit after every meaningful step. Never build a long design
  or big code only inside a chat reply - put it on disk in small pieces first.
- When and only when the WHOLE task is fully complete, run: touch $DONE_FILE"
try=0
while [ ! -f "$DONE_FILE" ] && [ "$try" -lt "$MAX_TRIES" ]; do
  try=$((try+1))
  n=0
  until curl -s -m 5 "$HEALTH_URL" 2>/dev/null | grep -q '"ok"'; do
    [ $((n % 10)) -eq 0 ] && echo "[$(ts)] super: endpoint down, waiting ($HEALTH_URL)" >> "$log"
    n=$((n+1)); sleep 30
  done
  if [ "$try" -eq 1 ] && ! has_session; then
    mode=fresh
    set -- -y -p "$(cat "$pf")$sfx"
  elif has_session; then
    mode=session-resume
    set -- -y -c -p "You were interrupted (crash or network outage) and this session was resumed. Re-check the workspace state (files may differ from what you remember), then continue the task to completion under the same rules. Reminder: touch $DONE_FILE only when fully complete."
  else
    mode=workspace-resume
    set -- -y -p "You are RESUMING an interrupted autonomous task. First re-read the full task: $pf
Then inspect the workspace (ls -laR, git log, STATUS/DEVLOG if present) to see
what is already done, and continue from there under the original rules.$sfx"
  fi
  echo "[$(ts)] super: attempt $try/$MAX_TRIES launching qwen ($mode)" >> "$log"
  ( cd "$ws" && QWEN_CODE_SUPPRESS_YOLO_WARNING=1 "$d/qwen-remote.sh" "$@" >> "$log" 2>&1 )
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
