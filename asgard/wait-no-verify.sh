#!/bin/sh
# /data/local-ai/asgard/wait-no-verify.sh [MAX_S] - block while a model-file verification (verify-slow.py, or a plain
# `sha256 -q`) is running: its NVMe read stream heats the PCH to 85-100 C, which drops the CPU turbo band (PCH >= WD_PCH_LO)
# and can cap the CPU (>= WD_PCH_HI), so every speed number taken meanwhile is invalid (2026-09-13: 40 MB/s reads were
# enough, the download itself is harmless at PCH 64-67 C). Prints a line when it starts/stops waiting.
# Exit 0 when clear, 1 when still busy after MAX_S seconds (default 3600). Used by sweep.sh (per config) and e2e-all.sh (per task).
max=${1:-3600}; t=0
while p=$(pgrep -fl "verify-slow.py|sha256 -q" 2>/dev/null); do
  [ $t -eq 0 ] && echo "$(date +%T) waiting for the model verification to finish: $(echo "$p" | head -1 | cut -c1-90)"
  [ $t -ge "$max" ] && { echo "$(date +%T) still verifying after $max s - not waiting any longer (numbers taken now are suspect)"; exit 1; }
  sleep 30; t=$((t + 30))
done
[ $t -gt 0 ] && echo "$(date +%T) verification finished after $t s of waiting; pch=$(sysctl -n dev.pchtherm.0.temperature)"
exit 0
