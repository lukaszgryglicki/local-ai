#!/bin/sh
# /data/local-ai/asgard/sweep.sh MODEL LABEL=SPEC[;EXTRA...] ... - spec-decoding / server-flag sweep on one model.
# Each config: stop server, idle GAP s (default 150 — lets the GPU fall back to ~60 °C so configs start alike),
# start with SPEC/EXTRA (+ any NP/CTX/THREADS/NCMOE in the environment), record thermal state, run
# codebench.py LABEL 2 (thinking on, greedy, MAXTOK tokens per answer), append CSV. Output in
# ~/local-ai-runs/sweep-MODEL.{csv,log}. Run detached: daemon -f -o ~/local-ai-runs/sweep-MODEL.log sweep.sh ...
# Example: sweep.sh qwen9b "mtp+ngram=draft-mtp,ngram-mod" "mtp=draft-mtp" "ngram=ngram-mod" "none=none"
#          sweep.sh north "n12=ngram-mod;--spec-draft-n-max 12"
d=$(dirname "$(realpath "$0")"); cd "$d" || exit 1
M=$1; shift; [ -n "$M" ] && [ $# -gt 0 ] || { echo "usage: sweep.sh MODEL LABEL=SPEC[;EXTRA] ..." >&2; exit 1; }
R=${LOCAL_AI_RUNS:-$HOME/local-ai-runs}; mkdir -p "$R"; OUT=$R/sweep-$M.csv; GAP=${GAP:-150}; MAXTOK=${MAXTOK:-2048}
st() { echo "pch=$(sysctl -n dev.pchtherm.0.temperature | cut -d. -f1) core=$(sysctl -n dev.cpu.0.temperature | cut -d. -f1) cap=$(cat /var/run/thermal-policy.ratio 2>/dev/null)00 gpu=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader)C"; }
echo "# sweep $M $(date '+%F %T') GAP=$GAP MAXTOK=$MAXTOK NP=${NP:-1} CTX=${CTX:-default}" >> "$OUT"
for cfg in "$@"; do
  label=${cfg%%=*}; rest=${cfg#*=}; spec=${rest%%;*}; extra=; case $rest in *\;*) extra=${rest#*;};; esac
  ./stop.sh >/dev/null 2>&1; sleep "$GAP"
  up=$(SPEC=$spec EXTRA=$extra ./start.sh "$M" 2>&1 | head -1 | cut -c1-120)
  case $up in UP*) ;; *) echo "$(date +%T) $label START_FAILED: $up"; echo "$label,START_FAILED" >> "$OUT"; continue;; esac
  echo "$(date +%T) $label START $(st) | $up"
  MAXTOK=$MAXTOK TEMP=0 python3 codebench.py "$label" 2 | tee -a "$OUT"
  echo "$(date +%T) $label END   $(st)"
  grep -q . "$R/guard.log" 2>/dev/null && echo "$label GUARD_LOG_NONEMPTY: $(tail -1 "$R/guard.log")"
done
./stop.sh >/dev/null 2>&1
echo "SWEEP_DONE $(date +%T)"
