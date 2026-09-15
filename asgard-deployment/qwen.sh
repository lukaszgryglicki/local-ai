#!/bin/sh
# /data/local-ai/asgard-deployment/qwen.sh [qwen-code args] - Qwen Code (the `qwen` CLI) against the asgard llama tier service.
# Installed as /data/scripts/qwen.sh (asgard: symlink into this directory; tuxi: copy) together with the tier-pinned wrappers
# /data/scripts/qwen-t0.sh, qwen-t1.sh, qwen-t2.sh (= TIER=t0|t1|t2 qwen.sh).
#   qwen.sh           connects to whichever tier is running on asgard (t0 / t1 / t2) and configures itself for it
#   qwen-t1.sh        insists on tier t1: refuses (and prints the service commands) when another tier is serving
# Where it runs:
#   on asgard   -> http://10.253.254.1:18080 directly (the llama-t0|t1|t2 services listen there)
#   elsewhere (tuxi) -> ssh tunnel 127.0.0.1:18080 -> asgard:10.253.254.1:18080, opened on demand (ssh -fN ... asgard) and
#                  left running; no llama runs on tuxi. LLAMA_SSH_HOST (asgard) and LLAMA_LOCAL_PORT (18080) override.
# Settings = the settled parameters of results-t0.md §5 / results-t1.md §6 / results-t2.md §4:
#   thinking on for all three tiers and reasoning_effort xhigh (= its maximum) for T2 - both enforced server-side by
#   llama-tier.sh; context window = the server's n_ctx (262 144 = the models' native maximum; 524 288 when started with yarn2);
#   one slot; sampling temp 1.0 / top_p 0.95 / top_k 20 / min_p 0 (Qwen thinking-mode card values = the server defaults);
#   max_tokens 32768 per turn (thinking + code in one turn); auto-compaction at 95 % of the window; no short client caps (12 h);
#   report_findings tool excluded (its JSON schema breaks the llama grammar converter -> HTTP 400); throwaway HOME
#   ($QWEN_ASGARD_HOME, default ~/.qwen-asgard, persistent so sessions survive) so the real qwen config stays untouched.
# Key: /data/local-ai/key.secret (identical on asgard and tuxi; LLAMA_KEY_FILE overrides).
# Headless use: qwen-t0.sh --yolo -p "prompt"        Interactive: qwen-t2.sh
set -u
TIER=${TIER:-}
KEY_FILE=${LLAMA_KEY_FILE:-/data/local-ai/key.secret}
[ -r "$KEY_FILE" ] || { echo "API key file $KEY_FILE is missing or unreadable" >&2; exit 1; }
KEY=$(cat "$KEY_FILE")
command -v qwen >/dev/null 2>&1 || { echo "the qwen CLI (Qwen Code) is not installed here: npm install -g @qwen-code/qwen-code" >&2; exit 1; }

if [ "$(hostname -s)" = asgard ] && ifconfig 2>/dev/null | grep -q 'inet 10.253.254.1 '; then
  BASE=http://10.253.254.1:18080; WHERE="asgard, local"
else   # remote host (tuxi): reach asgard's 10.253.254.1:18080 through an ssh tunnel (tuxi has its own 10.253.254.1, hence 127.0.0.1)
  LPORT=${LLAMA_LOCAL_PORT:-18080}; BASE=http://127.0.0.1:$LPORT; WHERE="ssh tunnel 127.0.0.1:$LPORT -> asgard"
  if ! { sockstat -4l 2>/dev/null || netstat -an 2>/dev/null; } | grep -q "127\.0\.0\.1[:.]$LPORT "; then
    # stdio detached: the background tunnel must not keep a caller's pipeline (qwen-t0.sh ... | tail) open
    ssh -fN -o ExitOnForwardFailure=yes -o BatchMode=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=4 \
      -L "127.0.0.1:$LPORT:10.253.254.1:18080" "${LLAMA_SSH_HOST:-asgard}" </dev/null >/dev/null 2>&1 \
      || { echo "cannot open the ssh tunnel to ${LLAMA_SSH_HOST:-asgard} (ssh key / host entry?)" >&2; exit 1; }
    sleep 1
  fi
fi

mid=$(curl -s -m 8 -H "Authorization: Bearer $KEY" "$BASE/v1/models" 2>/dev/null | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -1)
[ -n "$mid" ] || { echo "no llama tier is serving ($WHERE: $BASE) - on asgard run:  sudo service llama-t0 start   (or llama-t1 / llama-t2)" >&2; exit 1; }
case "$mid" in
  qwen3.6-35b-a3b)    got=t0; TITLE='T0 fastest-vram: Qwen3.6-35B-A3B UD-IQ2_M (all in VRAM)' ;;
  qwen3.6-35b-a3b-q4) got=t1; TITLE='T1 fast: Qwen3.6-35B-A3B UD-Q4_K_XL' ;;
  qwen3.8-flash-next) got=t2; TITLE='T2 best: Qwen3.8-Flash-Next UD-IQ4_XS (reasoning effort xhigh)' ;;
  *)                  got=other; TITLE="asgard llama: $mid" ;;
esac
if [ -n "$TIER" ] && [ "$TIER" != "$got" ]; then
  echo "asgard is serving $got ($mid), not $TIER. Either use qwen.sh / qwen-$got.sh, or switch tiers on asgard:" >&2
  echo "  sudo service llama-$got stop && sudo service llama-$TIER start" >&2
  exit 1
fi
nctx=$(curl -s -m 8 -H "Authorization: Bearer $KEY" "$BASE/props" 2>/dev/null | sed -n 's/.*"n_ctx":\([0-9][0-9]*\).*/\1/p' | head -1)
[ -n "$nctx" ] || nctx=262144

h=${QWEN_ASGARD_HOME:-$HOME/.qwen-asgard}
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
  "model": {"name": "$mid"},
  "fastModel": "$mid",
  "compactionModel": "$mid",
  "modelProviders": {"openai": [{
    "id": "$mid",
    "name": "asgard $TITLE",
    "envKey": "LOCAL_LLM_API_KEY",
    "baseUrl": "$BASE/v1",
    "generationConfig": {
      "contextWindowSize": $nctx,
      "timeout": 43200000,
      "streamIdleTimeoutMs": 43200000,
      "maxRetries": 1,
      "samplingParams": {"temperature": 1.0, "top_p": 0.95, "top_k": 20, "min_p": 0.0, "max_tokens": 32768}
    }
  }]}
}
EOF
[ -n "${QWEN_QUIET:-}" ] || echo "asgard llama $got: $TITLE | ctx $nctx | $WHERE" >&2
export QWEN_STREAM_MAX_LIFETIME_MS="${QWEN_STREAM_MAX_LIFETIME_MS:-0}"
export QWEN_STREAM_IDLE_TIMEOUT_MS="${QWEN_STREAM_IDLE_TIMEOUT_MS:-43200000}"
export QWEN_CODE_API_TIMEOUT_MS="${QWEN_CODE_API_TIMEOUT_MS:-43200000}"
export QWEN_CODE_TOOL_EXECUTION_TIMEOUT_MS="${QWEN_CODE_TOOL_EXECUTION_TIMEOUT_MS:-43200000}"
LOCAL_LLM_API_KEY=$KEY HOME="$h" exec qwen --auth-type openai --model "$mid" "$@"
