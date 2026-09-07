#!/bin/sh
# /data/local-ai/health.sh - is the local model served and actually generating?
d=$(dirname "$(realpath "$0")")
u=http://10.253.254.1:18080
h=$(curl -s -m 5 "$u/health") || { echo "DOWN: no answer on $u/health"; exit 1; }
echo "$h" | grep -q '"ok"\|ok' || { echo "UNHEALTHY: $h"; exit 1; }
r=$(curl -s -m 120 "$u/v1/chat/completions" \
  -H "Authorization: Bearer $(cat "$d/key.secret")" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3coder-local","messages":[{"role":"user","content":"Reply with exactly: OK"}],"max_tokens":8,"temperature":0}')
echo "$r" | grep -q '"content"' || { echo "SERVED BUT NOT GENERATING: $r"; exit 1; }
echo "HEALTHY: server up, model generating ($u, alias qwen3coder-local)"
