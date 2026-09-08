#!/bin/sh
# /data/ai/serve-new.sh - Qwen3.8-Flash-Next UD-Q6_K_XL on the big-MoE serving node (CPU only).
# Bench-tuned rewrite of serve.sh (2026-09-08 A/B results — llama-speed-research.md):
#   nice 19->5        llama is 2nd priority after the primary workload, but not starved
#   threads 24->16    same tok/s (bandwidth-bound), +8 cores back to the primary workload
#   cache-ram -1      kills prompt-cache evictions (93/day -> ~0) & 5-15 min re-prefills
#   ngram-simple->draft-mtp,ngram-mod  MTP head: +25% cold gen (accept ~0.9);
#                     ngram-mod: up to +160% on edit/repeat loops; combo best everywhere
# MTP needs the PATCHED binary (qwen4exp MTP graph port) + the draft head gguf:
#   rsync <model-node>:/data/ai/src/llama.cpp  -> /data/ai/src/  (build/bin/llama-server)
#   rsync <model-node>:/data/ai/models-small/Qwen3.8-Flash-Next-MTP-Q4_K_M.gguf -> /data/ai/models-small/
# Falls back to stock binary + ngram-mod alone when either is missing.
# Loopback-only (:18080) - reach remotely via ssh -L tunnel.
# Jailed: MemoryHigh 190G / MemoryMax 200G, cores 0-43 (12 left for the primary workload).
d=$(dirname "$(realpath "$0")")
# EFFORT=medium ./serve-new.sh to lower reasoning (default xhigh); levels: low|medium|xhigh
EFFORT=${EFFORT:-xhigh}
# PAR=1 for a single slot (default 4: 1 foreground + background agents, np is speed-free)
PAR=${PAR:-4}
# CTX1M=1 - ONE slot with 1M-token context via YaRN (4x native 262144). Opt-in only.
CTX1M=${CTX1M:-0}
# MTP=0 to disable the draft head even when available
MTP=${MTP:-1}
if [ "$CTX1M" = "1" ]; then
  PAR=1
  CTX_ARGS="--ctx-size 1048576 --parallel 1 --rope-scaling yarn --rope-scale 4.0 --yarn-orig-ctx 262144"
else
  CTX_ARGS="--ctx-size $((262144*PAR)) --parallel $PAR"
fi

BIN_PATCHED="$d/src/llama.cpp/build/bin/llama-server"
MTP_HEAD="$d/models-small/Qwen3.8-Flash-Next-MTP-Q4_K_M.gguf"
if [ "$MTP" = "1" ] && [ -x "$BIN_PATCHED" ] && [ -s "$MTP_HEAD" ]; then
  BIN="$BIN_PATCHED"
  SPEC_ARGS="--model-draft $MTP_HEAD --spec-type draft-mtp,ngram-mod --spec-draft-n-max 6 --spec-draft-p-min 0.75"
else
  BIN="$d/llama-server"
  SPEC_ARGS="--spec-type ngram-mod"
fi

exec systemd-run --scope --collect -q \
  -p MemoryHigh=190G -p MemoryMax=200G -p AllowedCPUs=0-43 \
  --setenv=LLAMA_ATTN_ROT_DISABLE=1 \
  nice -n 5 "$BIN" --model "$d/models/Qwen3.8-Flash-Next-UD-Q6_K_XL-00001-of-00006.gguf" \
  --alias qwen38flash --host 127.0.0.1 --port 18080 \
  $CTX_ARGS \
  --cache-type-k q8_0 --cache-type-v q8_0 \
  --batch-size 2048 --ubatch-size 1024 --threads 16 --threads-batch 44 \
  --cache-ram -1 \
  $SPEC_ARGS --jinja --reasoning-effort "$EFFORT" \
  --temp 1.0 --top-p 0.95 --top-k 20 --min-p 0.0 --repeat-penalty 1.0 \
  --no-mmproj --no-ui --no-agent --offline --timeout 43200 \
  --api-key-file "$d/key.secret" --log-file /data/ai/llama.log
