#!/bin/sh
# /data/ai/serve.sh - Qwen3.8-Flash-Next UD-Q6_K_XL on devstats-compute-02 (CPU only).
# Loopback-only (:18080) - reach remotely via ssh -L tunnel. parallel=1 like tuxedo.
# Jailed: MemoryHigh 190G / MemoryMax 200G, cores 0-43 (12 left for devstats), nice 19.
# Weights are mmap'd (file-backed, kernel-reclaimable) -> cannot OOM the node.
d=$(dirname "$(realpath "$0")")
# EFFORT=medium ./serve.sh to lower reasoning (default xhigh); levels: low|medium|xhigh
EFFORT=${EFFORT:-xhigh}
# PAR=1 ./serve.sh for a single slot (default 4: 1 foreground + background agents,
# each slot gets its own 262144 ctx; extra slots also stop cache eviction by health checks)
PAR=${PAR:-4}
# CTX1M=1 ./serve.sh - ONE slot with 1M-token context via YaRN rope scaling (4x native
# 262144, officially supported by Qwen). Opt-in only: static YaRN can slightly degrade
# sub-256K quality, and filling 1M at ~49 tok/s pp takes hours - use for giant jobs only.
CTX1M=${CTX1M:-0}
if [ "$CTX1M" = "1" ]; then
  PAR=1
  CTX_ARGS="--ctx-size 1048576 --parallel 1 --rope-scaling yarn --rope-scale 4.0 --yarn-orig-ctx 262144"
else
  CTX_ARGS="--ctx-size $((262144*PAR)) --parallel $PAR"
fi
exec systemd-run --scope --collect -q \
  -p MemoryHigh=190G -p MemoryMax=200G -p AllowedCPUs=0-43 \
  nice -n 19 "$d/llama-server" --model "$d/models/Qwen3.8-Flash-Next-UD-Q6_K_XL-00001-of-00006.gguf" \
  --alias qwen38flash --host 127.0.0.1 --port 18080 \
  $CTX_ARGS \
  --cache-type-k q8_0 --cache-type-v q8_0 \
  --batch-size 2048 --ubatch-size 1024 --threads 24 --threads-batch 44 \
  --spec-type ngram-simple --jinja --reasoning-effort "$EFFORT" \
  --temp 1.0 --top-p 0.95 --top-k 20 --min-p 0.0 --repeat-penalty 1.0 \
  --no-mmproj --no-ui --no-agent --offline --timeout 43200 \
  --api-key-file "$d/key.secret" --log-file /data/ai/llama.log
