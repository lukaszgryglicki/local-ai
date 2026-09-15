#!/bin/sh
# /data/scripts/qwen-t0.sh [qwen-code args] - qwen.sh pinned to tier t0: T0 fastest-vram (Qwen3.6-35B-A3B UD-IQ2_M, all in VRAM).
# Refuses when asgard serves another tier (prints the service commands to switch). Everything else: qwen.sh next to this file.
TIER=t0 exec "$(dirname "$(realpath "$0")")/qwen.sh" "$@"
