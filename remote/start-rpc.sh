#!/bin/bash
# RPC backend for multi-node model split. Run on each helper node.
# Binds to this node 10.60.0.x VLAN IP only (never public). THREADS=16 default.
# -c caches received tensors for fast reloads. LLAMA_CACHE forces the cache
# onto the big /data disk (default ~/.cache/llama.cpp sits on the small root
# fs and WILL fill it -> kubelet DiskPressure -> pod evictions. Never again.)
# Jailed like the main server: memory capped + niced so the primary tenants
# of these nodes always win CPU/RAM.
ip=$(ip -4 -o a show dev eth0 | grep -o "10\.60\.0\.[0-9]*" | head -1)
[ -z "$ip" ] && { echo "no 10.60.0.x VLAN IP found"; exit 1; }
cd /data/ai/rpc-bin
export LD_LIBRARY_PATH=/data/ai/rpc-bin
export LLAMA_CACHE=/data/ai/cache
mkdir -p "$LLAMA_CACHE/rpc"
echo "RPC backend on $ip:50052 (threads ${THREADS:-16}, cache $LLAMA_CACHE/rpc)"
exec systemd-run --scope --collect -q \
  -p MemoryHigh=170G -p MemoryMax=180G -p AllowedCPUs=0-43 \
  nice -n 5 ./ggml-rpc-server -H "$ip" -p 50052 -t ${THREADS:-16} -c
