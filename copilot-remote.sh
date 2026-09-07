#!/bin/sh
# /data/local-ai/copilot-remote.sh - run INSIDE the bhyve VM; connects to the remote
# model (Qwen3.8-Flash-Next on devstats-compute-02) through the host tunnel.
# From the VM this dir is /freebsd/data/local-ai. Tunnel must be running on the host.
d=$(dirname "$(realpath "$0")")
COPILOT_PROVIDER_TYPE=openai COPILOT_PROVIDER_BASE_URL=http://10.253.254.1:18081/v1 COPILOT_PROVIDER_API_KEY=$(cat "$d/remote-key.secret") COPILOT_MODEL=qwen38flash exec copilot --model qwen38flash "$@"
