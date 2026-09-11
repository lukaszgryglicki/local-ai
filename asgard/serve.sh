#!/bin/sh
# /data/local-ai/asgard/serve.sh MODEL - start the local model server on asgard.
# Layout: EVERYTHING in Quadro VRAM (--gpu-layers 99 --device Vulkan0, X runs on the iGPU so all
# 16 GiB are free): weights + 256K q8_0 KV + compute buffers. No --cpu-moe / --no-kv-offload here.
# Same host/port as tuxi's ../serve.sh (10.253.254.1:18080) and the extra alias qwen3coder-local,
# so ../qwen.sh, ../health.sh, ../copilot.sh work unchanged on asgard; asgard/qwen.sh adds
# per-model sampling. MODEL = north | qwen9b | gemma | qwen35b (asgard/models.sh).
# Env overrides: NP slots (default 1; ctx = NP x 256K unless CTX given), CTX, THREADS (8),
# THREADS_BATCH (16), NCMOE (--n-cpu-moe, default per model), SPEC (--spec-type, default per
# model; SPEC=none for raw decode speed), LOG, EXTRA (appended verbatim).
# Pinned-cap rules (plan §6): --load-mode none, never --check-tensors / GGML_VK_PREFER_HOST_MEMORY,
# --cache-ram from models.sh, --spec-type from models.sh (draft-mtp only for *-MTP-GGUF files).
# Stop the server before suspend (zzz) - VRAM survival across S3 is untested.
d=$(dirname "$(realpath "$0")")
. "$d/models.sh"; model_env "${1:-north}" || exit 1
B=/data/ai/local-agent-poc/src/llama.cpp/build-vulkan/bin/llama-server
NP=${NP:-1}; CTX=${CTX:-$((262144 * NP))}
n=${NCMOE:-$MODEL_NCMOE}; NCMOE_ARGS=; [ "$n" -gt 0 ] && NCMOE_ARGS="--n-cpu-moe $n"
KW_ARGS=; [ -n "$MODEL_KWARGS" ] && KW_ARGS="--chat-template-kwargs $MODEL_KWARGS"
export GGML_VK_VISIBLE_DEVICES=0
exec "$B" --model "$d/../models/$MODEL_FILE" --alias "$MODEL_ALIAS,qwen3coder-local" \
  --host 10.253.254.1 --port 18080 \
  --ctx-size "$CTX" --parallel "$NP" --gpu-layers 99 --device Vulkan0 --fit off $NCMOE_ARGS \
  --flash-attn on --cache-type-k q8_0 --cache-type-v q8_0 --cache-ram "$MODEL_CACHE_RAM" \
  --batch-size 2048 --ubatch-size 1024 --threads "${THREADS:-8}" --threads-batch "${THREADS_BATCH:-16}" \
  --load-mode none --ctx-checkpoints 8 \
  --spec-type "${SPEC:-$MODEL_SPEC}" --spec-draft-n-max 6 --spec-draft-p-min 0.75 \
  --jinja --reasoning on --reasoning-budget -1 $KW_ARGS \
  --temp "$MODEL_TEMP" --top-p "$MODEL_TOP_P" --top-k "$MODEL_TOP_K" --min-p "$MODEL_MIN_P" --repeat-penalty 1.0 \
  --no-mmproj --no-ui --no-agent --offline --timeout 43200 --api-key-file "$d/../key.secret" \
  --log-file "${LOG:-${LOCAL_AI_RUNS:-$HOME/local-ai-runs}/llama.log}" $EXTRA
