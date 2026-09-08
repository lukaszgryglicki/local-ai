#!/bin/bash
# /data/ai/bench.sh - A/B benchmark of llama-server speed knobs on devstats-compute-02.
# DO NOT run while the production server (:18080) is busy with a real task -
# it starts its own instances on :18081 and the two would fight for CPU.
# Usage: ./bench.sh [quick|full]   (quick = 4 variants ~20min, full = all ~1h)
# Results: /data/ai/bench-results.txt (appended, one line per variant)
set -u
D=/data/ai
PORT=18081
MODEL=$D/models/Qwen3.8-Flash-Next-UD-Q6_K_XL-00001-of-00006.gguf
KEY=$(cat $D/key.secret)
RES=$D/bench-results.txt
MODE=${1:-quick}

# Fixed workload: ~8000-token prompt (realistic agentic prefill) + 256-token gen x3.
mkprompt() {
  python3 - <<'EOF'
import random
random.seed(42)
words = ("func main package import return if else for range var const chess board "
         "move engine search depth eval alpha beta node hash table thread core").split()
print("Analyze this Go code and explain the search algorithm in detail:")
for i in range(700):
    print(f"// line {i}: " + " ".join(random.choices(words, k=12)))
print("Now write a detailed technical explanation of iterative deepening alpha-beta search.")
EOF
}
PROMPT_FILE=/tmp/bench-prompt.txt
[ -s $PROMPT_FILE ] || mkprompt > $PROMPT_FILE
PROMPT=$(python3 -c "import json,sys; print(json.dumps(open('$PROMPT_FILE').read()))")

run_variant() {
  local name="$1"; shift
  echo "=== variant: $name ($*)" | tee -a $RES
  systemd-run --scope --collect -q -p MemoryHigh=190G -p MemoryMax=200G -p AllowedCPUs=0-43 \
    $D/llama-server --model $MODEL --host 127.0.0.1 --port $PORT \
    --jinja --reasoning-effort low --temp 1.0 --top-p 0.95 --top-k 20 --min-p 0.0 \
    --no-mmproj --no-ui --no-agent --offline --api-key-file $D/key.secret \
    --log-file /tmp/bench-$name.log "$@" &
  local SPID=$!
  # wait for health (model load from page cache ~30-60s)
  for i in $(seq 1 120); do
    curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:$PORT/health 2>/dev/null | grep -q 200 && break
    sleep 2
  done
  # req 1 = cold pp measurement; reqs 2-4 hit the prompt cache -> pure tg samples.
  # Extract pp/tg from the server's own timing log.
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
  kill $SPID 2>/dev/null; sleep 3
  # ensure port free
  fuser -k $PORT/tcp 2>/dev/null; sleep 2
}

CTX="--ctx-size 524288 --parallel 2"      # 2x256K during bench (faster load than 4x)
BASE="--cache-type-k q8_0 --cache-type-v q8_0 --batch-size 2048"

# --- baseline = current production settings (minus parallel) ---
run_variant base    $CTX $BASE --ubatch-size 1024 --threads 24 --threads-batch 44 --spec-type ngram-simple
[ "$MODE" = quick ] && {
run_variant t32     $CTX $BASE --ubatch-size 1024 --threads 32 --threads-batch 44 --spec-type ngram-simple
run_variant t28     $CTX $BASE --ubatch-size 1024 --threads 28 --threads-batch 44 --spec-type ngram-simple
run_variant best    $CTX $BASE --ubatch-size 2048 --threads 32 --threads-batch 44 --spec-type ngram-simple \
                    --cache-ram -1 --poll 100
echo "quick done - see $RES"; exit 0; }

# --- full sweep ---
# thread descent: tg is memory-bandwidth bound; optimum may be below 24
run_variant t20      $CTX $BASE --ubatch-size 1024 --threads 20 --threads-batch 44 --spec-type ngram-simple
run_variant t16      $CTX $BASE --ubatch-size 1024 --threads 16 --threads-batch 44 --spec-type ngram-simple
run_variant t12      $CTX $BASE --ubatch-size 1024 --threads 12 --threads-batch 44 --spec-type ngram-simple
run_variant t8       $CTX $BASE --ubatch-size 1024 --threads 8  --threads-batch 44 --spec-type ngram-simple
# other knobs on the t24 winner base
run_variant ub2048   $CTX $BASE --ubatch-size 2048 --threads 24 --threads-batch 44 --spec-type ngram-simple
run_variant nospec   $CTX $BASE --ubatch-size 1024 --threads 24 --threads-batch 44 --spec-type none
run_variant ngmapk4v $CTX $BASE --ubatch-size 1024 --threads 24 --threads-batch 44 --spec-type ngram-map-k4v
run_variant ngmod    $CTX $BASE --ubatch-size 1024 --threads 24 --threads-batch 44 --spec-type ngram-mod
run_variant np1      --ctx-size 262144 --parallel 1 $BASE --ubatch-size 1024 --threads 24 --threads-batch 44 --spec-type ngram-simple
run_variant np4      --ctx-size 1048576 --parallel 4 $BASE --ubatch-size 1024 --threads 24 --threads-batch 44 --spec-type ngram-simple
run_variant fp16kv   --ctx-size 524288 --parallel 2 --batch-size 2048 --ubatch-size 1024 --threads 24 --threads-batch 44 --spec-type ngram-simple
run_variant combo    $CTX $BASE --ubatch-size 1024 --threads 24 --threads-batch 44 --spec-type ngram-map-k4v \
                    --cache-ram -1 --poll 100 --flash-attn on
echo "full sweep done - see $RES"
