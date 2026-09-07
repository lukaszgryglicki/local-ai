#!/bin/sh
# /data/ai/qwen.sh - coding session against the local server (compute-02).
# Throwaway HOME; internet tools enabled; report_findings excluded (grammar bug).
# max_tokens 16384: thinking output shares the per-turn budget.
d=$(dirname "$(realpath "$0")")
h=/tmp/ai-qwen-home
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
  "model": {"name": "qwen38flash"},
  "fastModel": "qwen38flash",
  "compactionModel": "qwen38flash",
  "modelProviders": {"openai": [{
    "id": "qwen38flash",
    "name": "Qwen3.8-Flash-Next Q6 (linode CPU)",
    "envKey": "LOCAL_LLM_API_KEY",
    "baseUrl": "http://127.0.0.1:18080/v1",
    "generationConfig": {
      "contextWindowSize": 262144,
      "timeout": 7200000,
      "streamIdleTimeoutMs": 7200000,
      "maxRetries": 1,
      "samplingParams": {"temperature": 1.0, "top_p": 0.95, "top_k": 20, "min_p": 0.0, "max_tokens": 16384}
    }
  }]}
}
EOF
LOCAL_LLM_API_KEY=$(cat "$d/key.secret") HOME="$h" exec qwen --auth-type openai --model qwen38flash "$@"
