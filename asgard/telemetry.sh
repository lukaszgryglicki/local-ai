#!/bin/sh
# /data/local-ai/asgard/telemetry.sh [CSV] - 5 s thermal/clock telemetry + PCH guard for llama-server runs.
#
# Why: 2026-09-11 21:05 the thermal watchdog powered asgard off (PCH 110 C) during a North sweep: under
# sustained GPU load the PCH climbs ~1 C / 10 s even with the CPU capped at 1.2 GHz (package 5-7 W), so
# a llama-server run must be stopped before the watchdog's hard `shutdown -p`. This script only
# observes and, at GUARD_PCH (default 102 C, watchdog crit is 110), runs asgard/stop.sh and logs the
# event; it changes no thermal setting. Run under daemon(8):
#   daemon -f -p ~/local-ai-runs/telemetry.pid /data/local-ai/asgard/telemetry.sh ~/local-ai-runs/telemetry.csv
# Columns: time,pch_c,core_max_c,cpu_max_mhz,cap_mhz,gpu_c,gpu_sm_mhz,gpu_w,gpu_util,gpu_throttle,server
d=$(dirname "$(realpath "$0")")
RUNS=${LOCAL_AI_RUNS:-$HOME/local-ai-runs}; mkdir -p "$RUNS"
CSV=${1:-$RUNS/telemetry.csv}
GUARD_PCH=${GUARD_PCH:-102}
EVENTS=${EVENTS:-$RUNS/guard.log}
[ -s "$CSV" ] || echo "time,pch_c,core_max_c,cpu_max_mhz,cap_mhz,gpu_c,gpu_sm_mhz,gpu_w,gpu_util,gpu_throttle,server" > "$CSV"
ncpu=$(sysctl -n hw.ncpu)
while :; do
  pch=$(sysctl -n dev.pchtherm.0.temperature 2>/dev/null | cut -d. -f1)
  cmax=0; f=0; i=0
  while [ $i -lt "$ncpu" ]; do
    t=$(sysctl -n dev.cpu.$i.temperature 2>/dev/null | cut -d. -f1); [ "${t:-0}" -gt "$cmax" ] && cmax=$t
    m=$(sysctl -n dev.cpu.$i.freq 2>/dev/null); [ "${m:-0}" -gt "$f" ] && f=$m
    i=$((i+1))
  done
  cap=$(( $(cat /var/run/thermal-policy.ratio 2>/dev/null || echo 24) * 100 ))
  if pgrep -q -x llama-server; then
    srv=1
    gpu=$(nvidia-smi --query-gpu=temperature.gpu,clocks.sm,power.draw,utilization.gpu,clocks_throttle_reasons.active \
          --format=csv,noheader,nounits 2>/dev/null | tr -d ' ' | tr ',' ' ')
    set -- $gpu; g_c=${1:-}; g_sm=${2:-}; g_w=${3:-}; g_u=${4:-}; g_r=${5:-}
  else
    srv=0; g_c=; g_sm=; g_w=; g_u=; g_r=   # do not wake an idle GPU (nvidia-smi re-inits it at P0)
  fi
  echo "$(date +%T),$pch,$cmax,$f,$cap,$g_c,$g_sm,$g_w,$g_u,$g_r,$srv" >> "$CSV"
  if [ "${pch:-0}" -ge "$GUARD_PCH" ] && [ "$srv" = 1 ]; then
    echo "$(date '+%F %T') GUARD PCH ${pch} C >= ${GUARD_PCH} C (core ${cmax} C, cap ${cap} MHz, gpu ${g_c} C ${g_w} W) -> stop.sh" | tee -a "$EVENTS"
    "$d/stop.sh" >> "$EVENTS" 2>&1
  fi
  sleep 5
done
