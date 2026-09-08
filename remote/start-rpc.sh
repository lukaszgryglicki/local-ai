#!/bin/bash
# RPC backend for multi-node model split. Run on each helper node.
# Binds to this node 10.60.0.x VLAN IP only (never public). THREADS=16 default.
# NO tensor cache (-c): measured 2026-09-08 - the cache saved only ~4 min of a
# ~44 min load (the main node must read+hash every tensor either way; the
# synchronous per-tensor RPC walk is the bottleneck) while writing ~248 GB to
# disk. Its old default location ~/.cache/llama.cpp also once filled the small
# root fs -> kubelet DiskPressure -> pod evictions. Cacheless is safer + equal.
# Jailed like the main server: memory capped + niced so the primary tenants
# of these nodes always win CPU/RAM.
ip=$(ip -4 -o a show dev eth0 | grep -o "10\.60\.0\.[0-9]*" | head -1)
[ -z "$ip" ] && { echo "no 10.60.0.x VLAN IP found"; exit 1; }
cd /data/ai/rpc-bin
export LD_LIBRARY_PATH=/data/ai/rpc-bin
echo "RPC backend on $ip:50052 (threads ${THREADS:-16}, no cache)"
exec systemd-run --scope --collect -q \
  -p MemoryHigh=170G -p MemoryMax=180G -p AllowedCPUs=0-43 \
  nice -n 5 ./ggml-rpc-server -H "$ip" -p 50052 -t ${THREADS:-16}
