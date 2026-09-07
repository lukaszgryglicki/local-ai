#!/bin/sh
# /data/local-ai/qwen.sh - coding session against the local server (FreeBSD host).
# Throwaway HOME so your real qwen config is untouched. Internet/web tools enabled.
# report_findings MUST stay excluded: its JSON schema breaks this llama build's
# grammar converter -> HTTP 400 on every request.
d=$(dirname "$(realpath "$0")")
h=/tmp/local-ai-qwen-home
mkdir -p "$h/.qwen"
cat > "$h/.qwen/settings.json" <<'EOF'
{
  "$version": 4,
  "general": {"enableAutoUpdate": false},
  "privacy": {"usageStatisticsEnabled": false},
  "telemetry": {"enabled": false, "logPrompts": false},
  "mcpServers": {},
  "tools": {"exclude": ["report_findings"]},
  "security": {"auth": {"selectedType": "openai"}},
  "model": {"name": "qwen3coder-local"},
  "fastModel": "qwen3coder-local",
  "compactionModel": "qwen3coder-local",
  "modelProviders": {"openai": [{
    "id": "qwen3coder-local",
    "name": "Local Qwen3-Coder-30B Q8_0",
    "envKey": "LOCAL_LLM_API_KEY",
    "baseUrl": "http://10.253.254.1:18080/v1",
    "generationConfig": {
      "contextWindowSize": 262144,
      "timeout": 7200000,
      "streamIdleTimeoutMs": 7200000,
      "maxRetries": 1,
      "samplingParams": {"temperature": 1.0, "top_p": 0.95, "top_k": 20, "min_p": 0.0, "max_tokens": 8192}
    }
  }]}
}
EOF
LOCAL_LLM_API_KEY=$(cat "$d/key.secret") HOME="$h" exec qwen --auth-type openai --model qwen3coder-local "$@"
