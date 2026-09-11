#!/bin/sh
# /data/local-ai/asgard/start.sh MODEL - daemonize asgard/serve.sh MODEL, wait until /health is ok
# (or the server dies), then print load time, VRAM use and the KV/compute buffer lines from the log.
# Env passes through to serve.sh (NP, CTX, THREADS, THREADS_BATCH, NCMOE, EXTRA). Stop: asgard/stop.sh
d=$(dirname "$(realpath "$0")")
RUNS=${LOCAL_AI_RUNS:-$HOME/local-ai-runs}; mkdir -p "$RUNS"   # /var/tmp is a 1 GiB tmpfs symlink on asgard (wiped at boot)
LOG=${LOG:-$RUNS/llama.log}; export LOG
PID=$RUNS/llama.pid
[ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null && { echo "already running (pid $(cat "$PID")) - asgard/stop.sh first"; exit 1; }
[ -f "$LOG" ] && mv "$LOG" "$LOG.prev"   # llama-server truncates --log-file on open; keep the previous run
t0=$(date +%s)
daemon -f -p "$PID" "$d/serve.sh" "${1:-north}" || exit 1
sleep 2
while :; do
  curl -s -m 2 http://10.253.254.1:18080/health 2>/dev/null | grep -q ok && break
  kill -0 "$(cat "$PID" 2>/dev/null)" 2>/dev/null || { echo "SERVER EXITED after $(( $(date +%s) - t0 )) s - last log lines:"; grep -vE "^\s*$" "$LOG" | tail -12 | cut -c1-200; exit 1; }
  sleep 1
done
echo "UP in $(( $(date +%s) - t0 )) s (pid $(cat "$PID")) | VRAM: $(nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader) | model=${1:-north} NP=${NP:-1} CTX=${CTX:-$((262144 * ${NP:-1}))} THREADS=${THREADS:-8}/${THREADS_BATCH:-16} NCMOE=${NCMOE:-default} SPEC=${SPEC:-default}"
grep -E "KV self size|KV size|compute buffer size|model buffer size|CPU_Mapped model buffer|Vulkan0 model buffer|Vulkan0 KV|n_ctx_seq|n_ctx_per_seq|slots|spec|draft|warning|error" | grep -v "^$" | cut -c1-160 | head -14
