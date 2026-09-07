#!/bin/sh
# /data/ai/qwen.sh - coding session against the local server (compute-02).
# Throwaway HOME; internet tools enabled; report_findings excluded (grammar bug).
# max_tokens 32768: thinking output shares the per-turn budget (xhigh thinks A LOT).
# NO short client caps: qwen-code's default 15-min stream-lifetime guard kills long
# xhigh thinking turns (seen: 12-min turn aborted mid-task). Lifetime cap disabled
# (0), all other caps 12h (43200000 ms) - covers 256K ctx in+out even < 10 tok/s.
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
      "timeout": 43200000,
      "streamIdleTimeoutMs": 43200000,
      "maxRetries": 1,
      "samplingParams": {"temperature": 1.0, "top_p": 0.95, "top_k": 20, "min_p": 0.0, "max_tokens": 32768}
    }
  }]}
}
EOF
export QWEN_STREAM_MAX_LIFETIME_MS="${QWEN_STREAM_MAX_LIFETIME_MS:-0}"
export QWEN_STREAM_IDLE_TIMEOUT_MS="${QWEN_STREAM_IDLE_TIMEOUT_MS:-43200000}"
export QWEN_CODE_API_TIMEOUT_MS="${QWEN_CODE_API_TIMEOUT_MS:-43200000}"
export QWEN_CODE_TOOL_EXECUTION_TIMEOUT_MS="${QWEN_CODE_TOOL_EXECUTION_TIMEOUT_MS:-43200000}"
LOCAL_LLM_API_KEY=$(cat "$d/key.secret") HOME="$h" exec qwen --auth-type openai --model qwen38flash "$@"
