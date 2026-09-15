#!/bin/sh
# /data/scripts/qwen-t1.sh [qwen-code args] - qwen.sh pinned to tier t1: T1 fast (Qwen3.6-35B-A3B UD-Q4_K_XL).
# Refuses when asgard serves another tier (prints the service commands to switch). Everything else: qwen.sh next to this file.
TIER=t1 exec "$(dirname "$(realpath "$0")")/qwen.sh" "$@"
