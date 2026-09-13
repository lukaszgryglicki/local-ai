#!/bin/sh
# /data/local-ai/asgard/sweep.sh MODEL LABEL=SPEC[;EXTRA...] ... - spec-decoding / server-flag sweep on one model.
# Each config: stop server, idle GAP s (default 150 — lets the GPU fall back to ~60 °C so configs start alike),
# start with SPEC/EXTRA (+ any NP/CTX/THREADS/NCMOE in the environment), record thermal state, run
# codebench.py LABEL 2 (thinking on, greedy, MAXTOK tokens per answer), append CSV. Output in
# ~/local-ai-runs/sweep-MODEL.{csv,log}. Run detached: daemon -f -o ~/local-ai-runs/sweep-MODEL.log sweep.sh ...
# A third ;-field sets environment variables for start.sh (NCMOE, IGPU_MOE, NP, CTX, THREADS, ...).
# BENCH=bench (T2 placement/threads sweeps on slow models): run bench.py LABEL $DEPTHS (default "64 4096", GEN=256)
# instead of codebench.py - ~5 min per config instead of 20-30 at 3 t/s; keep codebench for the 2-3 finalists.
# Each config first waits for mains power (wait-ac.sh: battery = CPU 1 GHz / GPU P5, 13 Sep 10:58) and then
# (wait-no-verify.sh, up to 90 min) while a download verification runs - its NVMe stream heats the
# PCH past 85 C and the watchdog drops the CPU turbo band / caps the CPU, which would falsify the numbers (2026-09-13).
# Example: sweep.sh qwen35b "ngram=ngram-mod" "none=none"
#          sweep.sh qwen35b-q4 "cpu20=none;;NCMOE=20" "n12=ngram-mod;--spec-draft-n-max 12"
#          sweep.sh qwen35b "vram=ngram-mod" "cpu5=ngram-mod;;NCMOE=5" "igpu5=ngram-mod;;IGPU_MOE=5"
d=$(dirname "$(realpath "$0")"); cd "$d" || exit 1
M=$1; shift; [ -n "$M" ] && [ $# -gt 0 ] || { echo "usage: sweep.sh MODEL LABEL=SPEC[;EXTRA] ..." >&2; exit 1; }
R=${LOCAL_AI_RUNS:-$HOME/local-ai-runs}; mkdir -p "$R"; OUT=$R/sweep-$M.csv; GAP=${GAP:-150}; MAXTOK=${MAXTOK:-2048}
st() { echo "pch=$(sysctl -n dev.pchtherm.0.temperature | cut -d. -f1) core=$(sysctl -n dev.cpu.0.temperature | cut -d. -f1) cap=$(cat /var/run/thermal-policy.ratio 2>/dev/null)00 gpu=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader)C"; }
LOG=${LOG:-$R/llama.log}
echo "# sweep $M $(date '+%F %T') GAP=$GAP MAXTOK=$MAXTOK NP=${NP:-1} CTX=${CTX:-default} BENCH=${BENCH:-code}${DEPTHS:+ DEPTHS=$DEPTHS} GEN=${GEN:-}" >> "$OUT"
for cfg in "$@"; do
  label=${cfg%%=*}; rest=${cfg#*=}; spec=${rest%%;*}; extra=; envs=
  case $rest in *\;*) rest=${rest#*;}; extra=${rest%%;*}; case $rest in *\;*) envs=${rest#*;};; esac;; esac
  ./stop.sh >/dev/null 2>&1; "$d/wait-ac.sh"; "$d/wait-no-verify.sh" 5400; sleep "$GAP"   # never measure on battery or during a model verification (PCH -> CPU cap)
  up=$(env $envs SPEC=$spec EXTRA="$extra" ./start.sh "$M" 2>&1 | head -1 | cut -c1-160)
  case $up in UP*) ;; *) echo "$(date +%T) $label START_FAILED: $up"; echo "$label,START_FAILED" >> "$OUT"; continue;; esac
  echo "$(date +%T) $label START $(st) ac=$(sysctl -n hw.acpi.acline) | $up"
  if [ "${BENCH:-code}" = bench ]; then
    GEN=${GEN:-256} python3 bench.py "$label" ${DEPTHS:-64 4096} | tee -a "$OUT"
    echo "    $(grep -E "model buffer size|KV self size" "$LOG" 2>/dev/null | cut -c1-120 | tr '\n' '|')"
    pid=$(cat "$R/llama.pid" 2>/dev/null); rss=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
    echo "    rss=$(( ${rss:-0} / 1024 )) MiB | VRAM $(nvidia-smi --query-gpu=memory.used --format=csv,noheader)"
  else
    MAXTOK=$MAXTOK TEMP=0 python3 codebench.py "$label" 2 | tee -a "$OUT"
  fi
  echo "$(date +%T) $label END   $(st) ac=$(sysctl -n hw.acpi.acline)"
  grep -q . "$R/guard.log" 2>/dev/null && echo "$label GUARD_LOG_NONEMPTY: $(tail -1 "$R/guard.log")"
done
./stop.sh >/dev/null 2>&1
echo "SWEEP_DONE $(date +%T)"
