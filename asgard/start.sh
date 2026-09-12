#!/bin/sh
# /data/local-ai/asgard/start.sh MODEL - daemonize asgard/serve.sh MODEL, wait until /health is ok
# (or the server dies), then print load time, VRAM use and the KV/compute buffer lines from the log.
# Env passes through to serve.sh (NP, CTX, THREADS, THREADS_BATCH, NCMOE, SPEC, EXTRA, IGPU_MOE, DEV, VKVIS). Stop: asgard/stop.sh
# Every start is remembered in ~/local-ai-runs/last-start.env; start.sh --last replays it (used by asgard/unstick.sh
# after a hung server had to be killed, e.g. after an S3 suspend with a request in flight).
d=$(dirname "$(realpath "$0")")
RUNS=${LOCAL_AI_RUNS:-$HOME/local-ai-runs}; mkdir -p "$RUNS"   # /var/tmp is a 1 GiB tmpfs symlink on asgard (wiped at boot)
LOG=${LOG:-$RUNS/llama.log}; export LOG
PID=$RUNS/llama.pid
if [ "${1:-}" = --last ]; then . "$RUNS/last-start.env" || exit 1; set -- "$LAST_MODEL"; echo "replaying: $(cat "$RUNS/last-start.env" | tr '\n' ' ')"; fi
[ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null && { echo "already running (pid $(cat "$PID")) - asgard/stop.sh first"; exit 1; }
# llama-server truncates --log-file on open: keep the previous run as $LOG.prev (e2e-test.sh reads it after a mid-task
# restart) and archive the one before that in $RUNS/logs/ (nothing is lost across quick restarts)
[ -f "$LOG.prev" ] && { mkdir -p "$RUNS/logs"; mv "$LOG.prev" "$RUNS/logs/llama-$(stat -f %Sm -t %Y%m%d-%H%M%S "$LOG.prev").log"; }
[ -f "$LOG" ] && mv "$LOG" "$LOG.prev"
OUT=$RUNS/serve.out; echo "=== $(date "+%F %T") start.sh ${1:-north} $(env | grep -E "^(NP|CTX|THREADS|THREADS_BATCH|NCMOE|SPEC|EXTRA|IGPU_MOE|DEV|VKVIS)=" | tr "\n" " ")" >> "$OUT"
t0=$(date +%s)
{ echo "LAST_MODEL=${1:-north}"; for v in NP CTX THREADS THREADS_BATCH NCMOE SPEC EXTRA IGPU_MOE DEV VKVIS DRAFT_KV GGML_VK_ALLOW_SYSMEM_FALLBACK; do eval "val=\${$v:-}"; [ -n "$val" ] && echo "export $v='$val'"; done; } > "$RUNS/last-start.env"
daemon -f -p "$PID" -o "$OUT" "$d/serve.sh" "${1:-north}" || exit 1   # -o: stderr (GGML_ASSERT, Vulkan errors, aborts) survives
sleep 2
while :; do
  curl -s -m 2 http://10.253.254.1:18080/health 2>/dev/null | grep -q ok && break
  kill -0 "$(cat "$PID" 2>/dev/null)" 2>/dev/null || { echo "SERVER EXITED after $(( $(date +%s) - t0 )) s - last log lines:"; grep -vE "^\s*$" "$LOG" | tail -12 | cut -c1-200; echo "-- stderr ($OUT):"; tail -8 "$OUT" | cut -c1-200; exit 1; }
  sleep 1
done
echo "UP in $(( $(date +%s) - t0 )) s (pid $(cat "$PID")) | VRAM: $(nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader) | model=${1:-north} NP=${NP:-1} CTX=${CTX:-$((262144 * ${NP:-1}))} THREADS=${THREADS:-8}/${THREADS_BATCH:-16} NCMOE=${NCMOE:-default} SPEC=${SPEC:-default}"
grep -E "KV self size|KV size|compute buffer size|model buffer size|CPU_Mapped model buffer|Vulkan0 model buffer|Vulkan0 KV|n_ctx_seq|n_ctx_per_seq|slots|spec|draft|warning|error" | grep -v "^$" | cut -c1-160 | head -14
