#!/bin/bash
# /data/ai/bench5.sh - MTP combo tuning draft-head + tuned ngram-mod benchmarks (patched build)
set -u
D=/data/ai
PORT=18081
BIN=$D/src/llama.cpp/build/bin/llama-server
BIGMODEL=$D/models/Qwen3.8-Flash-Next-UD-Q6_K_XL-00001-of-00006.gguf
MTPQ4=$D/models-small/Qwen3.8-Flash-Next-MTP-Q4_K_M.gguf
MTPBF=$D/models-small/Qwen3.8-Flash-Next-MTP-BF16.gguf
RES=$D/bench5-results.txt

PROMPT_FILE=/tmp/bench-prompt.txt
[ -s $PROMPT_FILE ] || { echo "missing $PROMPT_FILE"; exit 1; }
PROMPT=$(python3 -c "import json,sys; print(json.dumps(open('$PROMPT_FILE').read()))")

run_variant() {
  local name="$1"; shift
  echo "=== variant: $name ($*)" | tee -a $RES
  systemd-run --scope --collect -q -p MemoryHigh=190G -p MemoryMax=200G -p AllowedCPUs=0-43 \
    --setenv=LLAMA_ATTN_ROT_DISABLE=1 \
    $BIN --model $BIGMODEL --host 127.0.0.1 --port $PORT \
    --ctx-size 524288 --parallel 2 --cache-type-k q8_0 --cache-type-v q8_0 \
    --batch-size 2048 --ubatch-size 1024 --threads 16 --threads-batch 44 \
    --jinja --reasoning-effort low --temp 1.0 --top-p 0.95 --top-k 20 --min-p 0.0 \
    --no-mmproj --no-ui --no-agent --offline --api-key-file $D/key.secret \
    --log-file /tmp/bench-$name.log "$@" &
  local SPID=$!
  local up=0
  for i in $(seq 1 150); do
    curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:$PORT/health 2>/dev/null | grep -q 200 && { up=1; break; }
    sleep 2
  done
  [ $up = 0 ] && { echo "  SERVER FAILED TO START" | tee -a $RES; tail -5 /tmp/bench-$name.log | sed 's/^/  | /' | tee -a $RES; kill $SPID 2>/dev/null; fuser -k $PORT/tcp 2>/dev/null; sleep 2; return; }
  KEY=$(cat $D/key.secret)
  for r in 1 2 3 4; do
    curl -s -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
      -d "{\"prompt\": $PROMPT, \"n_predict\": 256, \"temperature\": 0, \"cache_prompt\": true}" \
      http://127.0.0.1:$PORT/completion > /dev/null
  done
  sleep 1
  grep "prompt eval time" /tmp/bench-$name.log | awk -F'[/(,]' \
    '{split($2,a," "); split($4,s," "); n++; if(a[1]>1000){pp[n]=s[1]}} END {printf "  cold-pp tok/s:"; for(i in pp) printf " %s", pp[i]; print ""}' | tee -a $RES
  grep -E "\| *eval time" /tmp/bench-$name.log | awk -F'[(,]' \
    '{split($3,s," "); v=v" "s[1]} END {print "  tg tok/s:" v}' | tee -a $RES
  grep -oE "draft acceptance rate = [0-9.]+" /tmp/bench-$name.log | tail -4 | awk '{v=v" "$5} END {print "  draft-accept:" v}' | tee -a $RES
  kill $SPID 2>/dev/null; sleep 3
  fuser -k $PORT/tcp 2>/dev/null; sleep 2
}

run_variant combo-bf16    --model-draft $MTPBF --spec-type draft-mtp,ngram-mod --spec-draft-n-max 3 --spec-draft-p-min 0.75
run_variant combo-bf16-n6 --model-draft $MTPBF --spec-type draft-mtp,ngram-mod --spec-draft-n-max 6 --spec-draft-p-min 0.75
run_variant combo-q4-n6   --model-draft $MTPQ4 --spec-type draft-mtp,ngram-mod --spec-draft-n-max 6 --spec-draft-p-min 0.75
echo "bench5 done - see $RES"
