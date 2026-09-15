#!/bin/sh
# /data/scripts/qwen-t2.sh [qwen-code args] - qwen.sh pinned to tier t2: T2 best (Qwen3.8-Flash-Next UD-IQ4_XS, reasoning effort xhigh).
# Refuses when asgard serves another tier (prints the service commands to switch). Everything else: qwen.sh next to this file.
TIER=t2 exec "$(dirname "$(realpath "$0")")/qwen.sh" "$@"
