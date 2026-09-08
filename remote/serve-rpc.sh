#!/bin/bash
# /data/ai/serve-rpc.sh - multi-node llama-server: this node + RPC backends
# (helpers run ./start-rpc.sh -> ggml-rpc-server :50052 on the private VLAN).
#
# PRODUCTION DEFAULT (2026-09-08): Ornith-1.5-397B Q8_0 (428.5 GB) split across
# 3 nodes; run this on the node holding models/Ornith-1.5-397B-Q8_0.gguf.
#   NGL=40 of 60 layers -> remotes (memory-proportional ~20+20), ~20 local (~143 GB/node)
#   PAR=4 slots; YARN=2 default: 524288 ctx/slot via YaRN 2x (~lossless).
#     YARN=1 = native 262144/slot (max quality), YARN=4 = 1M/slot (soft long-range recall).
#     KV is ~4 KB/token (hybrid linear attn, 15/60 full-attn layers, f16 cache):
#     4 slots cost ~4/8/16 GB at 1x/2x/4x - PAR stays 4 in every mode.
#   ngram-mod speculation (no MTP sidecar GGUF published for the 397B yet; SPEC=0 off)
#   sampling per Ornith generation_config: temp 0.6 / top-p 0.95 / top-k 20
#   jailed like serve-new.sh: MemoryHigh 190G / Max 200G, cores 0-43, nice 5
#
# NEXT MODEL: GLM-5.3-Flash Q8_0 (341 GB, TRUE 1M native ctx, A18B, effort control)
#   once llama.cpp PR #27754 (glm5_next) merges - as of 2026-09-08 the PR still has an
#   unresolved long-context repeating-token collapse bug, so we wait for the merge.
#
# Historical POC mode (small models) still available via knobs, e.g.:
#   MODEL=qwen25-coder-7b-q4km NGL=18 YARN=1 CTX=32768 PORT=18081 SPEC=0 ./serve-rpc.sh
# Knobs: MODEL PAR YARN NGL PORT RPC THREADS TB SPEC CTX (total-ctx override) NATIVE
d=$(dirname "$(realpath "$0")")
b=$d/src/llama.cpp/build-rpc/bin; [ -x "$b/llama-server" ] || b=$d/rpc-bin
PAR=${PAR:-4}; YARN=${YARN:-2}; NATIVE=${NATIVE:-262144}
NGL=${NGL:-40}; PORT=${PORT:-18080}; THREADS=${THREADS:-16}; TB=${TB:-44}; SPEC=${SPEC:-1}
MODEL=${MODEL:-Ornith-1.5-397B-Q8_0}
case "$MODEL" in
  /*) m=$MODEL ;;
  *)  m=$d/models/$MODEL.gguf; [ -s "$m" ] || m=$d/models-small/$MODEL.gguf ;;
esac
[ -s "$m" ] || { echo "model not found: $MODEL"; exit 1; }
own=$(ip -4 -o a show dev eth0 | grep -o "10\.60\.0\.[0-9]*" | head -1)
if [ -z "$RPC" ]; then
  for ip in 10.60.0.21 10.60.0.22 10.60.0.32; do
    [ "$ip" = "$own" ] && continue
    timeout 1 bash -c "echo > /dev/tcp/$ip/50052" 2>/dev/null && RPC="${RPC:+$RPC,}$ip:50052"
  done
fi
[ -z "$RPC" ] && { echo "no RPC backends reachable on :50052 (run start-rpc.sh on helpers)"; exit 1; }
case "$m" in *Ornith-1.5-397B*)
  case "$RPC" in *,*) ;; *) echo "Ornith Q8_0 needs BOTH helpers up (only $RPC reachable)"; exit 1 ;; esac ;;
esac
if [ "$YARN" = "1" ]; then
  CTX_ARGS="--ctx-size ${CTX:-$((NATIVE*PAR))} --parallel $PAR"
else
  CTX_ARGS="--ctx-size ${CTX:-$((NATIVE*YARN*PAR))} --parallel $PAR --rope-scaling yarn --rope-scale $YARN.0 --yarn-orig-ctx $NATIVE"
fi
SPEC_ARGS=""; [ "$SPEC" = "1" ] && SPEC_ARGS="--spec-type ngram-mod --spec-draft-n-max 6"
alias=$(basename "$m" .gguf)
echo "main=$own rpc=$RPC model=$m ngl=$NGL par=$PAR yarn=${YARN}x port=$PORT"
export LD_LIBRARY_PATH=$b
exec systemd-run --scope --collect -q \
  -p MemoryHigh=190G -p MemoryMax=200G -p AllowedCPUs=0-43 \
  nice -n 5 "$b/llama-server" -m "$m" --alias "$alias" \
  --host 127.0.0.1 --port "$PORT" \
  --rpc "$RPC" -ngl "$NGL" \
  $CTX_ARGS \
  --batch-size 2048 --ubatch-size 1024 --threads "$THREADS" --threads-batch "$TB" \
  --cache-ram -1 \
  $SPEC_ARGS --jinja \
  --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0.0 --repeat-penalty 1.0 \
  --no-mmproj --no-ui --no-agent --offline --timeout 43200 \
  --api-key-file "$d/key.secret" --log-file /data/ai/llama.log
