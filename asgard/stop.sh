#!/bin/sh
# /data/local-ai/asgard/stop.sh - stop the llama server (TERM, KILL after 30 s); prints VRAM after.
# Finds it via ~/local-ai-runs/llama.pid (asgard/start.sh) or, when there is no live pid there, via the process
# listening on :18080 (sockstat) - so a server started by hand (daemon -f ./serve.sh ...) is stopped too.
RUNS=${LOCAL_AI_RUNS:-$HOME/local-ai-runs}; PORT=${PORT:-18080}
PID=$RUNS/llama.pid
p=$(cat "$PID" 2>/dev/null) && kill -0 "$p" 2>/dev/null && how="pid $p from $PID"
if [ -z "$how" ]; then
  p=$(sockstat -4l -p "$PORT" 2>/dev/null | awk 'NR>1 && $2 ~ /^llama/ {print $3; exit}')
  [ -n "$p" ] || { rm -f "$PID"; echo "no server (no live pid in $PID, nothing listening on :$PORT)"; exit 0; }
  how="pid $p listening on :$PORT (started by hand, no pidfile)"
fi
kill "$p" 2>/dev/null || { echo "cannot signal $how, owner $(ps -o user= -p "$p" | tr -d ' ') - run as that user or root"; exit 1; }
for i in $(seq 1 30); do kill -0 "$p" 2>/dev/null || break; sleep 1; done
kill -0 "$p" 2>/dev/null && { echo "still alive after 30 s, sending KILL"; kill -9 "$p"; sleep 2; }
rm -f "$PID"; echo "stopped $how | VRAM now: $(nvidia-smi --query-gpu=memory.used --format=csv,noheader)"
