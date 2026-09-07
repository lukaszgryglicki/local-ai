#!/bin/sh
# /data/local-ai/health-remote.sh - is the REMOTE model reachable through the
# tunnel and actually generating? Works on the host (127.0.0.1:18081) and in
# the bhyve VM (falls back to 10.253.254.1:18081). Needs tunnel.sh running.
d=$(dirname "$(realpath "$0")")
u=http://127.0.0.1:18081
curl -s -m 5 "$u/health" >/dev/null 2>&1 || u=http://10.253.254.1:18081
h=$(curl -s -m 5 "$u/health") || { echo "DOWN: no answer on $u/health (tunnel.sh running? serve.sh on remote?)"; exit 1; }
echo "$h" | grep -q '"ok"\|ok' || { echo "UNHEALTHY: $h"; exit 1; }
r=$(curl -s -m 300 "$u/v1/chat/completions" \
  -H "Authorization: Bearer $(cat "$d/remote-key.secret")" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen38flash","messages":[{"role":"user","content":"Reply with exactly: OK"}],"max_tokens":512,"temperature":0}')
echo "$r" | grep -q '"content"' || { echo "SERVED BUT NOT GENERATING: $r"; exit 1; }
echo "HEALTHY: remote server up, model generating ($u, alias qwen38flash)"
