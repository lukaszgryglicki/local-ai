#!/bin/bash
# RPC backend for multi-node model split. Run on each helper node.
# Binds to this node 10.60.0.x VLAN IP only (never public). THREADS=16 default.
# -c caches received tensors under ~/.cache/llama.cpp/rpc for fast reloads.
ip=$(ip -4 -o a show dev eth0 | grep -o "10\.60\.0\.[0-9]*" | head -1)
[ -z "$ip" ] && { echo "no 10.60.0.x VLAN IP found"; exit 1; }
cd /data/ai/rpc-bin
export LD_LIBRARY_PATH=/data/ai/rpc-bin
echo "RPC backend on $ip:50052 (threads ${THREADS:-16})"
exec ./ggml-rpc-server -H "$ip" -p 50052 -t ${THREADS:-16} -c
