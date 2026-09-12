#!/bin/sh
# /data/local-ai/asgard/unstick.sh check|fix|watch [SECONDS] - detect (and repair) a llama-server whose GPU work will
# never finish. Seen on 2026-09-12 after an S3 suspend with a request in flight: the process, /health and /slots stay
# alive, the slot says is_processing, but the main loop sleeps in ggml_vk_wait_for_fence -> libnvidia-eglcore poll()
# on a fence submitted before the suspend and the GPU sits at 0 % / 300 MHz forever; the client (qwen-code) waits
# with it, silently. Fresh Vulkan contexts work fine, so the fix is: kill -9 (TERM is ignored in that state) and
# asgard/start.sh --last; a running E2E task then sees an API error and e2e-test.sh resumes its session by itself.
#   check          exit 0 = idle or working, 2 = STUCK (slot processing and GPU 0 % for STUCK_AFTER (60) s of samples)
#   fix            check, and if stuck: save diagnostics to ~/local-ai-runs/unstick/, kill -9, start.sh --last
#   watch [SEC]    loop: check every SEC (30) s, fix when stuck; e2e-test.sh runs this in the background during a task
#   kill           no check: kill -9 + start.sh --last right away (after a manual zzz when you know it is stuck)
# Never fires when the slot is idle (client-side tool execution) or when the GPU shows any utilisation.
d=$(dirname "$(realpath "$0")"); u=http://10.253.254.1:18080; k=$(cat "$d/../key.secret")
RUNS=${LOCAL_AI_RUNS:-$HOME/local-ai-runs}; PID=$RUNS/llama.pid; STUCK_AFTER=${STUCK_AFTER:-60}
processing() { curl -s -m 5 -H "Authorization: Bearer $k" "$u/slots" 2>/dev/null | grep -q '"is_processing":true'; }
gpu_busy() { [ "$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')" != 0 ]; }
check() {   # stuck = every 5 s sample over STUCK_AFTER s shows "processing and GPU 0 %"
  p=$(cat "$PID" 2>/dev/null) && kill -0 "$p" 2>/dev/null || return 0
  n=0; while [ $n -lt $((STUCK_AFTER / 5)) ]; do processing || return 0; gpu_busy && return 0; n=$((n + 1)); sleep 5; done
  return 2
}
fix() {   # $1 = force: skip the check
  if [ "${1:-}" != force ]; then check && { echo "$(date '+%F %T') unstick: not stuck"; return 0; }; fi
  p=$(cat "$PID"); D=$RUNS/unstick; mkdir -p "$D"; ts=$(date +%Y%m%d-%H%M%S)
  { echo "$(date '+%F %T') llama-server pid $p STUCK: slot processing, GPU 0 % for $STUCK_AFTER s"; uptime; nvidia-smi --query-gpu=utilization.gpu,power.draw,memory.used,clocks.sm --format=csv,noheader
    curl -s -m 5 -H "Authorization: Bearer $k" "$u/slots" | cut -c1-300; echo; procstat -kk "$p" 2>/dev/null | awk 'NR>1{$1=$2="";print}' | sort | uniq -c | sort -rn | head -3
    tail -3 "$RUNS/llama.log"; } > "$D/stuck-$ts.txt" 2>&1
  echo "$(date '+%F %T') STUCK -> kill -9 $p and start.sh --last (diagnostics: $D/stuck-$ts.txt)" | tee -a "$D/unstick.log"
  kill -9 "$p"; sleep 3; rm -f "$PID"
  "$d/start.sh" --last 2>&1 | tee -a "$D/unstick.log"
}
case ${1:-check} in
  check) check && { echo "ok: $( [ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null && echo server alive || echo no server )"; exit 0; } || { echo "STUCK"; exit 2; } ;;
  fix) fix ;;
  kill) fix force ;;
  watch) while :; do fix; sleep "${2:-30}"; done ;;
  *) sed -n '2,14p' "$0"; exit 1 ;;
esac
