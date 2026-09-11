#!/bin/sh
# /data/local-ai/asgard/stop.sh - stop the server started by asgard/start.sh (TERM, then wait); prints VRAM after.
RUNS=${LOCAL_AI_RUNS:-$HOME/local-ai-runs}
PID=$RUNS/llama.pid
p=$(cat "$PID" 2>/dev/null) || { echo "no pidfile"; exit 0; }
kill "$p" 2>/dev/null
for i in $(seq 1 30); do kill -0 "$p" 2>/dev/null || break; sleep 1; done
kill -0 "$p" 2>/dev/null && { echo "still alive after 30 s, sending KILL"; kill -9 "$p"; sleep 2; }
rm -f "$PID"; echo "stopped | VRAM now: $(nvidia-smi --query-gpu=memory.used --format=csv,noheader)"
