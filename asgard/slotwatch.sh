#!/bin/sh
# slotwatch.sh [interval_s] — append one line per interval about the llama-server slot 0 (read-only, no completion is sent):
#   HH:MM:SS task=ID busy|idle prompt=N processed=N decoded=N tg=T/S pch=C core=C gpu=C,W,util%,SMmhz
# tg = tokens decoded since the previous sample / elapsed (same task only). Uses GET /slots with the API key from
# /data/local-ai/key.secret; server address from LLAMA_URL (default = the llama-tier.sh bind address).
# Usage: daemon -f -p ~/local-ai-runs/slotwatch.pid -o ~/local-ai-runs/slotwatch.log /data/local-ai/asgard/slotwatch.sh 30
I=${1:-30}
URL=${LLAMA_URL:-http://10.253.254.1:18080}
KEY=$(cat /data/local-ai/key.secret 2>/dev/null)
prev_task=""; prev_dec=""; prev_t=""
while :; do
  now=$(date +%s)
  slot=$(curl -s -m 5 -H "Authorization: Bearer $KEY" "$URL/slots" 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for s in d:
    nt = s.get("next_token") or {}
    if isinstance(nt, list):
        nt = nt[0] if nt else {}
    print(s.get("id_task", -1), "busy" if s.get("is_processing") else "idle", s.get("n_prompt_tokens", 0),
          s.get("n_prompt_tokens_processed", 0), nt.get("n_decoded", 0))
    break
')
  if [ -z "$slot" ]; then
    echo "$(date +%T) server unreachable"
  else
    set -- $slot
    task=$1; state=$2; prompt=$3; proc=$4; dec=$5
    tg="-"
    if [ "$task" = "$prev_task" ] && [ -n "$prev_dec" ] && [ "$dec" -gt "$prev_dec" ] 2>/dev/null; then
      tg=$(awk -v a="$dec" -v b="$prev_dec" -v t="$((now - prev_t))" 'BEGIN { if (t > 0) printf "%.2f", (a - b) / t; else print "-" }')
    fi
    pch=$(sysctl -n dev.pchtherm.0.temperature 2>/dev/null | cut -d. -f1)
    core=$(sysctl -n dev.cpu.0.temperature 2>/dev/null | cut -d. -f1)
    gpu=$(nvidia-smi --query-gpu=temperature.gpu,power.draw,utilization.gpu,clocks.sm --format=csv,noheader,nounits 2>/dev/null |
          tr -d ' ' | awk -F, '{printf "%sC,%sW,%s%%,%sMHz", $1, $2, $3, $4}')
    echo "$(date +%T) task=$task $state prompt=$prompt processed=$proc decoded=$dec tg=$tg pch=$pch core=$core gpu=$gpu"
    prev_task=$task; prev_dec=$dec; prev_t=$now
  fi
  sleep "$I"
done
