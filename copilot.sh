#!/bin/sh
# /data/local-ai/copilot.sh - run INSIDE the bhyve VM (dockaws); connects to the
# model served on the FreeBSD host. From the VM this dir is /freebsd/data/local-ai.
# Keeps your real copilot login/config and full internet access - only the chat
# model is local (BYOK pattern).
d=$(dirname "$(realpath "$0")")
COPILOT_PROVIDER_TYPE=openai COPILOT_PROVIDER_BASE_URL=http://10.253.254.1:18080/v1 COPILOT_PROVIDER_API_KEY=$(cat "$d/key.secret") COPILOT_MODEL=qwen3coder-local exec copilot --model qwen3coder-local "$@"
