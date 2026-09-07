#!/bin/sh
# /data/local-ai/serve.sh - start the local model server (FreeBSD host).
# Fixed: parallel=1, ctx 256K. parallel=2 (2x256K slots) needs ~58G (weights 30.25 + KV q8 25.5 + bufs 2) > ~55G available on 61.75G host -> impossible.
# Layout: --gpu-layers 99 --cpu-moe --no-kv-offload = attention weights on iGPU (GTT), expert FFNs + KV + attention compute on CPU/RAM.
# --threads 12: best for deep agent prompts (+19% tg at 16K depth; shallow 11.09 vs 11.36@t10 - negligible); 16 (full SMT) collapses generation 11 -> 1.4 tok/s.
# --ubatch-size 1024: max stable at 256K (2048 = instant DeviceLost); pp 121 tok/s measured on 20.7K prompt.
# --spec-type ngram-simple: lossless self-speculation, echo-heavy output 12-35 tok/s, fresh output ~10 shallow / ~5 at 20K depth.
d=$(dirname "$(realpath "$0")")
exec "$d/llama" --model "$d/model.gguf" --alias qwen3coder-local --host 10.253.254.1 --port 18080 --ctx-size 262144 --parallel 1 --gpu-layers 99 --cpu-moe --no-kv-offload --load-mode none --cache-type-k q8_0 --cache-type-v q8_0 --flash-attn on --batch-size 2048 --ubatch-size 1024 --threads 12 --threads-batch 12 --spec-type ngram-simple --jinja --reasoning-effort medium --temp 1.0 --top-p 0.95 --top-k 20 --min-p 0.0 --repeat-penalty 1.0 --no-mmproj --no-ui --no-agent --offline --timeout 7200 --api-key-file "$d/key.secret" --log-file /tmp/local-ai-llama.log
