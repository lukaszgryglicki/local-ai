#!/bin/bash
# /data/ai/serve-rpc.sh - multi-node llama-server: this node + RPC backends
# (helpers run ./start-rpc.sh -> ggml-rpc-server :50052 on the private VLAN).
#
# PRODUCTION DEFAULT (2026-09-08): Ornith-1.5-397B Q8_0 (428.5 GB) split across
# 3 nodes; run this on the node holding models/Ornith-1.5-397B-Q8_0.gguf.
#   NGL=40 of 60 layers -> remotes (memory-proportional ~20+20), ~20 local (~143 GB/node)
#   PAR=4 slots; YARN=1 default (2026-09-09): native 262144 ctx/slot, max quality
#     - the 12h overnight run never exceeded ~53K, so no YaRN extension by default.
#     YARN=2 = 524288/slot via YaRN 2x (~lossless), YARN=4 = 1M/slot (soft recall).
#     KV is ~4 KB/token (hybrid linear attn, 15/60 full-attn layers, f16 cache):
#     4 slots cost ~4/8/16 GB at 1x/2x/4x - PAR stays 4 in every mode.
#   ngram-mod speculation (no MTP sidecar GGUF published for the 397B yet; SPEC=0 off)
#   sampling per Ornith generation_config: temp 0.6 / top-p 0.95 / top-k 20
#   jailed like serve-new.sh: MemoryHigh 190G / Max 200G, cores 0-43, nice 5
#
# tg DECAYS with context depth (measured 2026-09-08: 3.0 t/s @24K -> 1.34 @53K;
# KV scan on the 15 full-attn layers). A/B/C BENCHED 2026-09-09 (128-tok gen at
# 2K/16K/32K/49K depth, /v1/chat/completions timings, tdb01 loopback):
#   A = defaults (T16, no FA, f16 KV):  pp 27.6/22.1/18.6  tg 3.33/2.20/2.29 (16/32/49K)
#   B = FA=on KVQ=q8_0:                 pp 18.1/11.4/7.9   tg 3.13/2.21/1.83  <- pp COLLAPSES
#   C = THREADS=24:                     pp 26.9/21.8/18.0  tg 2.70/2.78/1.81  <- tg loses 2of3
# VERDICT: defaults win -> keep FA/KVQ OFF, THREADS=16. CPU flash-attn + KV
# dequant costs far exceed the smaller-KV win; T24 only helps a narrow mid-depth
# band. Knobs kept for future re-testing (new llama.cpp versions / models):
#   FA=on KVQ=q8_0 THREADS=24|32
# Client-side COMPACT policy (owner): default 0.9-0.95, full-context quality
# first; optional speed setting allowed but never below 0.5 (lossy summaries).
#
# NEXT MODEL: GLM-5.3-Flash Q8_0 (320.76B MoE A18B, TRUE 1M native ctx, effort
#   control) once llama.cpp PR #27754 (glm5_next) merges. Status 2026-09-09:
#   still OPEN, but the long-context repeating-token ("@") collapse turned out
#   METAL-ONLY (int32 dst-offset overflow in mul_mm.metal past 2^31; CPU-only is
#   clean at the same depth) -> does NOT affect this all-CPU rig. Remaining
#   blocker for agent use: branch still has supports_tool_calls=false (template).
#   Perf outlook vs Ornith at equal Q8: similar tg (A18B vs Ornith's A17B); the
#   wins are TRUE 1M ctx (no YaRN) + community-validated small quants: unsloth
#   UD-IQ4_XS (~147 GB) fits ONE node = no RPC hops (reported several-x tg vs Q8).
#
# Historical POC mode (small models) still available via knobs, e.g.:
#   MODEL=qwen25-coder-7b-q4km NGL=18 YARN=1 CTX=32768 PORT=18081 SPEC=0 ./serve-rpc.sh
# Knobs: MODEL PAR YARN NGL PORT RPC THREADS TB SPEC CTX (total-ctx override) NATIVE FA KVQ
d=$(dirname "$(realpath "$0")")
b=$d/src/llama.cpp/build-rpc/bin; [ -x "$b/llama-server" ] || b=$d/rpc-bin
PAR=${PAR:-4}; YARN=${YARN:-1}; NATIVE=${NATIVE:-262144}
NGL=${NGL:-40}; PORT=${PORT:-18080}; THREADS=${THREADS:-16}; TB=${TB:-44}; SPEC=${SPEC:-1}
FA=${FA:-}; KVQ=${KVQ:-}
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
    # 3s + one retry: helpers briefly stall the accept loop while freeing ~150G
    # after the previous main exits (1s probe false-negatived on 2026-09-09)
    for try in 1 2; do
      timeout 3 bash -c "echo > /dev/tcp/$ip/50052" 2>/dev/null && { RPC="${RPC:+$RPC,}$ip:50052"; break; }
      sleep 2
    done
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
XTRA_ARGS=""
[ -n "$FA" ] && XTRA_ARGS="--flash-attn $FA"
[ -n "$KVQ" ] && XTRA_ARGS="$XTRA_ARGS --cache-type-k $KVQ --cache-type-v $KVQ"
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
  $SPEC_ARGS $XTRA_ARGS --jinja \
  --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0.0 --repeat-penalty 1.0 \
  --no-mmproj --no-ui --no-agent --offline --timeout 43200 \
  --api-key-file "$d/key.secret" --log-file /data/ai/llama.log
