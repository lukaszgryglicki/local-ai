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
OUT=$RUNS/serve.out; echo "=== $(date "+%F %T") start.sh ${1:-qwen35b} $(env | grep -E "^(NP|CTX|THREADS|THREADS_BATCH|NCMOE|SPEC|EXTRA|IGPU_MOE|DEV|VKVIS)=" | tr "\n" " ")" >> "$OUT"
t0=$(date +%s)
{ echo "LAST_MODEL=${1:-qwen35b}"; for v in NP CTX THREADS THREADS_BATCH NCMOE SPEC EXTRA IGPU_MOE DEV VKVIS DRAFT_KV GGML_VK_ALLOW_SYSMEM_FALLBACK; do eval "val=\${$v:-}"; [ -n "$val" ] && echo "export $v='$val'"; done; } > "$RUNS/last-start.env"
daemon -f -p "$PID" -o "$OUT" "$d/serve.sh" "${1:-qwen35b}" || exit 1   # -o: stderr (GGML_ASSERT, Vulkan errors, aborts) survives
sleep 2
while :; do
  curl -s -m 2 http://10.253.254.1:18080/health 2>/dev/null | grep -q ok && break
  kill -0 "$(cat "$PID" 2>/dev/null)" 2>/dev/null || { echo "SERVER EXITED after $(( $(date +%s) - t0 )) s - last log lines:"; grep -vE "^\s*$" "$LOG" | tail -12 | cut -c1-200; echo "-- stderr ($OUT):"; tail -8 "$OUT" | cut -c1-200; exit 1; }
  sleep 1
done
echo "UP in $(( $(date +%s) - t0 )) s (pid $(cat "$PID")) | VRAM: $(nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader) | model=${1:-qwen35b} NP=${NP:-1} CTX=${CTX:-$((262144 * ${NP:-1}))} THREADS=${THREADS:-default}/${THREADS_BATCH:-16} NCMOE=${NCMOE:-default} SPEC=${SPEC:-default}"
grep -E "KV self size|KV size|compute buffer size|model buffer size|CPU_Mapped model buffer|Vulkan0 model buffer|Vulkan0 KV|n_ctx_seq|n_ctx_per_seq|slots|spec|draft|warning|error" | grep -v "^$" | cut -c1-160 | head -14
# soft-start (14 Sep 2026): all four AC-adapter dropouts of the campaign happened when the GPU jumped from idle to full
# power within milliseconds (first prefill/warm-up after a load: 12 Sep 23:10:41 at a 124.6 W spike, 13 Sep 10:58:07 one
# second after UP, 14 Sep 07:02:01 at the first depth-bench prefill) and every dropout left the GPU pinned until a cold
# power-off (results-t1.md 3.1, 6.1). Ramp the load in steps instead of one step: 1 -> 16 -> ... -> 2048 prompt tokens,
# 4 generated tokens each, 2 s apart (~20-40 s). SOFTSTART=0 skips it. This does not replace the adapter/jack check.
# Drop #5 (14 Sep 08:36:59) showed every dropout sits on a *partial-offload* prefill (expert weights streamed over PCIe to
# the GPU + CPU/RAM busy); the all-VRAM T0 model never dropped at the same GPU power - the ramp can only soften the step.
if [ "${SOFTSTART:-1}" != 0 ]; then
  # 14 Sep 08:50 fix: the first version sent no API key -> every ramp request was a 401 and the "4/4" was a no-op.
  # 14 Sep 12:10 (drop #6 hit the server's built-in warm-up right at UP): serve.sh now runs --no-warmup, so this ramp IS the
  # first GPU work; it is ramp.py (1 -> 4 -> 16 -> ... -> RAMP_MAX tokens back-to-back, no gaps, so the GPU boost controller is
  # engaged before the big steps). bench.py/codebench.py/e2e-test.sh call the same ramp immediately before their first request,
  # because a ramp minutes earlier (settle wait in between) leaves an idle GPU again.
  t1=$(date +%s); out=$(RAMP_MAX=${RAMP_MAX:-4096} python3 "$d/ramp.py" 2>&1 | tail -1)
  echo "soft-start: ${out#ramp: } ($(( $(date +%s) - t1 )) s)"
fi
