#!/bin/sh
# /data/local-ai/qwen-remote.sh - qwen-code on the FreeBSD host against the remote model.
# Needs the tunnel running first:
#   /data/local-ai/tunnel.sh   (serves 127.0.0.1:18081 + 10.253.254.1:18081)
# Default remote: Ornith-1.5-397B Q8_0, 3-node RPC via remote/serve-rpc.sh
#   (ctx below matches the server's YARN=1 default = native 262144/slot).
# Legacy mode: REMOTE_MODEL=qwen38flash ./qwen-remote.sh
#   (Qwen3.8-Flash-Next Q6 single node via remote/serve-new.sh).
# NO short client caps: lifetime cap disabled (0), all other caps 12h (43200000 ms).
# maxRetries 5000: the openai SDK retries connection errors/429/5xx with backoff
# capped at ~8 s -> qwen keeps RETRYING for ~11 h instead of dying when the
# tunnel/network drops BETWEEN requests. A drop MID-STREAM still fails the turn
# (SDK cannot resume a broken stream) - qwen-super.sh catches that outer case.
# COMPACT: chat-compression threshold (fraction of ctx window). Default 0.9 =
# compact late (max fidelity). POLICY (owner, 2026-09-09): default stays 0.9
# (0.95 ok) - full model context and quality first; compaction is LOSSY
# summarization, not compression. Optional speed tweak allowed but NEVER below
# 0.5 (tg decays with depth: ~3 t/s @24K -> ~1.4 @53K -> ~0.4-0.5 @256K).
d=$(dirname "$(realpath "$0")")
h=/tmp/remote-ai-qwen-home
mkdir -p "$h/.qwen"
REMOTE_MODEL=${REMOTE_MODEL:-ornith15-397b}
COMPACT=${COMPACT:-0.9}
if [ "$REMOTE_MODEL" = "qwen38flash" ]; then
  MNAME="Qwen3.8-Flash-Next Q6 (remote CPU)"; MCTX=262144; MTEMP=1.0
else
  MNAME="Ornith-1.5-397B Q8_0 (remote 3-node CPU)"; MCTX=262144; MTEMP=0.6
fi
cat > "$h/.qwen/settings.json" <<JSON
{
  "\$version": 4,
  "general": {"enableAutoUpdate": false},
  "privacy": {"usageStatisticsEnabled": false},
  "telemetry": {"enabled": false, "logPrompts": false},
  "mcpServers": {},
  "tools": {"exclude": ["report_findings"]},
  "security": {"auth": {"selectedType": "openai"}},
  "model": {"name": "$REMOTE_MODEL", "chatCompression": {"contextPercentageThreshold": $COMPACT}},
  "fastModel": "$REMOTE_MODEL",
  "compactionModel": "$REMOTE_MODEL",
  "modelProviders": {"openai": [{
    "id": "$REMOTE_MODEL",
    "name": "$MNAME",
    "envKey": "LOCAL_LLM_API_KEY",
    "baseUrl": "http://127.0.0.1:18081/v1",
    "generationConfig": {
      "contextWindowSize": $MCTX,
      "timeout": 43200000,
      "streamIdleTimeoutMs": 43200000,
      "maxRetries": 5000,
      "samplingParams": {"temperature": $MTEMP, "top_p": 0.95, "top_k": 20, "min_p": 0.0, "max_tokens": 32768}
    }
  }]}
}
JSON
export QWEN_STREAM_MAX_LIFETIME_MS="${QWEN_STREAM_MAX_LIFETIME_MS:-0}"
export QWEN_STREAM_IDLE_TIMEOUT_MS="${QWEN_STREAM_IDLE_TIMEOUT_MS:-43200000}"
export QWEN_CODE_API_TIMEOUT_MS="${QWEN_CODE_API_TIMEOUT_MS:-43200000}"
export QWEN_CODE_TOOL_EXECUTION_TIMEOUT_MS="${QWEN_CODE_TOOL_EXECUTION_TIMEOUT_MS:-43200000}"
LOCAL_LLM_API_KEY=$(cat "$d/remote-key.secret") HOME="$h" exec qwen --auth-type openai --model "$REMOTE_MODEL" "$@"
