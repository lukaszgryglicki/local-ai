#!/bin/sh
# /data/local-ai/asgard/wait-ac.sh [MAX_S] - block while the laptop runs on battery (hw.acpi.acline = 0): the EC caps the
# CPU at ~1 GHz / 6 W and the Quadro at P5 360 MHz, so any speed number taken on battery is garbage (13 Sep 10:58 the
# adapter dropped in the middle of a sweep and two configs were "measured" 3.5x slow). Polls every 30 s, prints one line
# when it starts waiting and one when mains is back; after mains returns it also requires 60 s of stable acline=1.
# Exit 0 = on mains, 1 = still on battery after MAX_S (default 6 h). Used by sweep.sh (per config) and e2e-all.sh (per task).
MAX_S=${1:-21600}; t0=$(date +%s); said=0
while :; do
  ac=$(sysctl -n hw.acpi.acline 2>/dev/null)
  if [ "$ac" = 1 ]; then
    [ $said = 1 ] && { sleep 60; [ "$(sysctl -n hw.acpi.acline)" = 1 ] || continue; echo "$(date '+%F %T') wait-ac: mains back, continuing"; }
    exit 0
  fi
  [ $said = 0 ] && { echo "$(date '+%F %T') wait-ac: ON BATTERY ($(sysctl -n hw.acpi.battery.life)%), waiting for mains"; said=1; }
  [ $(( $(date +%s) - t0 )) -ge "$MAX_S" ] && { echo "$(date '+%F %T') wait-ac: still on battery after $MAX_S s, giving up"; exit 1; }
  sleep 30
done
