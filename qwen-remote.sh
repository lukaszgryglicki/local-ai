#!/bin/sh
# /data/local-ai/qwen-remote.sh - qwen-code on the FreeBSD host against the remote model
# (Qwen3.8-Flash-Next on devstats-compute-02). Needs the tunnel running first:
#   /data/local-ai/tunnel.sh   (serves 127.0.0.1:18081 + 10.253.254.1:18081)
d=$(dirname "$(realpath "$0")")
h=/tmp/remote-ai-qwen-home
mkdir -p "$h/.qwen"
cat > "$h/.qwen/settings.json" <<'JSON'
{
  "$version": 4,
  "general": {"enableAutoUpdate": false},
  "privacy": {"usageStatisticsEnabled": false},
  "telemetry": {"enabled": false, "logPrompts": false},
  "mcpServers": {},
  "tools": {"exclude": ["report_findings"]},
  "security": {"auth": {"selectedType": "openai"}},
  "model": {"name": "qwen38flash"},
  "fastModel": "qwen38flash",
  "compactionModel": "qwen38flash",
  "modelProviders": {"openai": [{
    "id": "qwen38flash",
    "name": "Qwen3.8-Flash-Next Q6 (remote CPU)",
    "envKey": "LOCAL_LLM_API_KEY",
    "baseUrl": "http://127.0.0.1:18081/v1",
    "generationConfig": {
      "contextWindowSize": 262144,
      "timeout": 7200000,
      "streamIdleTimeoutMs": 7200000,
      "maxRetries": 1,
      "samplingParams": {"temperature": 1.0, "top_p": 0.95, "top_k": 20, "min_p": 0.0, "max_tokens": 16384}
    }
  }]}
}
JSON
LOCAL_LLM_API_KEY=$(cat "$d/remote-key.secret") HOME="$h" exec qwen --auth-type openai --model qwen38flash "$@"
