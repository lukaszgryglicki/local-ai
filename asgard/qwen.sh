#!/bin/sh
# /data/local-ai/asgard/qwen.sh [qwen args] - qwen-code session against the asgard server (run on asgard).
# MODEL=north|qwen9b|gemma|qwen35b (default qwen35b, the T-1 winner) must match what asgard/serve.sh is serving: it sets
# the model name shown in the UI and the per-model sampling (asgard/models.sh). Everything else as in
# ../qwen.sh: throwaway HOME so the real qwen config is untouched, report_findings excluded (its JSON
# schema breaks this llama build's grammar converter -> HTTP 400), no short client caps (lifetime cap
# 0, others 12h). max_tokens 32768: thinking + code in one turn; North allows 64K output.
# context.autoCompactThreshold 0.95: auto-compaction only at 95% of the 256K window (qwen default 0.85).
# Headless: MODEL=north asgard/qwen.sh --yolo -o stream-json "prompt"   (see asgard/rust-test.sh)
d=$(dirname "$(realpath "$0")")
. "$d/models.sh"; model_env "${MODEL:-qwen35b}" || exit 1
h=${LOCAL_AI_RUNS:-$HOME/local-ai-runs}/qwen-home
mkdir -p "$h/.qwen"
cat > "$h/.qwen/settings.json" <<EOF
{
  "\$version": 4,
  "general": {"enableAutoUpdate": false},
  "privacy": {"usageStatisticsEnabled": false},
  "telemetry": {"enabled": false, "logPrompts": false},
  "mcpServers": {},
  "tools": {"exclude": ["report_findings"]},
  "context": {"autoCompactThreshold": 0.95},
  "security": {"auth": {"selectedType": "openai"}},
  "model": {"name": "$MODEL_ALIAS"},
  "fastModel": "$MODEL_ALIAS",
  "compactionModel": "$MODEL_ALIAS",
  "modelProviders": {"openai": [{
    "id": "$MODEL_ALIAS",
    "name": "asgard local $MODEL_TITLE",
    "envKey": "LOCAL_LLM_API_KEY",
    "baseUrl": "http://10.253.254.1:18080/v1",
    "generationConfig": {
      "contextWindowSize": 262144,
      "timeout": 43200000,
      "streamIdleTimeoutMs": 43200000,
      "maxRetries": 1,
      "samplingParams": {"temperature": $MODEL_TEMP, "top_p": $MODEL_TOP_P, "top_k": $MODEL_TOP_K, "min_p": $MODEL_MIN_P, "max_tokens": 32768}
    }
  }]}
}
EOF
export QWEN_STREAM_MAX_LIFETIME_MS="${QWEN_STREAM_MAX_LIFETIME_MS:-0}"
export QWEN_STREAM_IDLE_TIMEOUT_MS="${QWEN_STREAM_IDLE_TIMEOUT_MS:-43200000}"
export QWEN_CODE_API_TIMEOUT_MS="${QWEN_CODE_API_TIMEOUT_MS:-43200000}"
export QWEN_CODE_TOOL_EXECUTION_TIMEOUT_MS="${QWEN_CODE_TOOL_EXECUTION_TIMEOUT_MS:-43200000}"
LOCAL_LLM_API_KEY=$(cat "$d/../key.secret") HOME="$h" exec qwen --auth-type openai --model "$MODEL_ALIAS" "$@"
