#!/bin/sh
# /data/local-ai/asgard/fit.sh MODEL k1 [k2 ...] - T1/T2 fit ladder over --n-cpu-moe: for each k (ascending = fewer
# expert layers in VRAM each step; k=all -> --cpu-moe) start the server with NCMOE=k at NP=${NP:-1}, ctx 262 144 per
# slot, record UP/EXITED + VRAM + load time + server RSS / Mem line (T2 host-RAM fits), stop it. Stops at the first k that comes up (set ALL=1 to run every k). Any other
# start.sh env (THREADS, SPEC, IGPU_MOE, EXTRA...) passes through. Log: ~/local-ai-runs/fit-MODEL.log (appended).
# Example: fit.sh qwen35b-q4 16 18 20 22 24
d=$(dirname "$(realpath "$0")"); cd "$d" || exit 1
M=$1; shift; [ -n "$M" ] && [ $# -gt 0 ] || { echo "usage: fit.sh MODEL k1 [k2 ...]" >&2; exit 1; }
R=${LOCAL_AI_RUNS:-$HOME/local-ai-runs}; mkdir -p "$R"; OUT=$R/fit-$M.log
echo "# fit $M $(date '+%F %T') NP=${NP:-1} THREADS=${THREADS:-8} SPEC=${SPEC:-default} IGPU_MOE=${IGPU_MOE:-0}" | tee -a "$OUT"
for k in "$@"; do
  ./stop.sh >/dev/null 2>&1; sleep 3
  up=$(NCMOE=$k ./start.sh "$M" 2>&1)
  line=$(echo "$up" | head -1 | cut -c1-200)
  case $line in
    UP*) echo "$(date +%T) NCMOE=$k $line" | tee -a "$OUT"
         echo "$up" | grep -E "KV self size|compute buffer|CPU_Mapped|model buffer size" | cut -c1-160 | sed 's/^/    /' | tee -a "$OUT"
         # T2: host memory matters as much as VRAM - server RSS (MiB) and the FreeBSD Mem/ARC lines after the load
         pid=$(cat "$R/llama.pid" 2>/dev/null); rss=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
         echo "    host: rss=$(( ${rss:-0} / 1024 )) MiB | $(top -b -n 0 | grep -E '^(Mem|ARC):' | tr '\n' ' ')" | tee -a "$OUT"
         ./stop.sh >/dev/null 2>&1; [ -n "$ALL" ] || break ;;
    *)   why=$(echo "$up" | grep -E "failed to allocate|out of memory|ErrorOutOfDeviceMemory|GGML_ASSERT|cannot run|error" | head -1 | cut -c1-160)
         echo "$(date +%T) NCMOE=$k $line :: $why" | tee -a "$OUT"; ./stop.sh >/dev/null 2>&1 ;;
  esac
done
echo "FIT_DONE $(date +%T)" | tee -a "$OUT"
