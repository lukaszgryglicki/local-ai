#!/bin/sh
# /data/local-ai/asgard-deployment/llama-tier.sh TIER COMMAND [yarn2]
#   TIER    = t0 | t1 | t2          COMMAND = start | stop | status | restart
# The frozen asgard llama service (Dell Precision 7750, Quadro RTX 5000 16 GiB via Vulkan, 128 GiB RAM, FreeBSD 15.1).
# One server at a time (every tier fills the 16 GiB card), always on http://10.253.254.1:18080, API key = /data/local-ai/key.secret.
# Called by the rc.d stubs (sudo service llama-t0|llama-t1|llama-t2 start|stop|status|restart) - or directly as the service user.
# Self-contained on purpose: the research scripts in /data/local-ai/asgard (models.sh, serve.sh, start.sh, ...) may change,
# this file carries the settled numbers (results-t0.md §5, results-t1.md §6, results-t2.md §4):
#
#   tier | profile      | model                                        | file        | placement                        | threads | spec | tg out t/s healthy -> GPU pinned
#   t0   | fastest-vram | Qwen3.6-35B-A3B UD-IQ2_M  (thinking on)      | 10.7 GiB    | all in VRAM (NCMOE=0)            | 8 / 16  | none | 61.5 -> 16.0   (never pins the GPU)
#   t1   | fast         | Qwen3.6-35B-A3B UD-Q4_K_XL (thinking on)     | 20.8 GiB    | experts of 20 layers in RAM      | 8 / 16  | none | 32.5 -> 11.0
#   t2   | best         | Qwen3.8-Flash-Next UD-IQ4_XS (thinking on,   | 87.3 GiB    | experts of 47/49 blocks in RAM   | 16 / 16 | none | ~4-5 (est.) -> 3.0
#        |              |   reasoning_effort xhigh = its maximum)      | (3 shards)  | (~58 GiB pinned + 27 GiB n-gram) |         |      |
#   common: ctx 262 144 per slot (the models' native maximum), --parallel 1, q8_0 KV, flash-attn, --cache-ram 8192,
#           sampling temp 1.0 / top_p 0.95 / top_k 20 / min_p 0 (Qwen thinking-mode card values), reasoning on, budget unlimited.
#
# Optional "yarn2": ctx 524 288 via YaRN x2 (--rope-scaling yarn --rope-scale 2 --yarn-orig-ctx 262144), works on all three tiers
# (load-tested 15 Sep). The doubled KV cache does not fit the card at q8_0 (every tier sits at 14.1-15.2 GiB of 16), so yarn2
# switches the KV cache to q4_0; t2 additionally runs batch 1024/512 (its 512K prefill compute buffer needs 9.3 GiB at 2048/1024).
# VRAM in the test: t0 14.9 GiB, t1 peaks at 16.0 GiB while loading (15.0 steady - no headroom), t2 11.2 GiB steady.
# Lower KV precision, and long-context quality beyond 256K is an untested extrapolation. yarn4 (1M) cannot fit in 16 GiB VRAM
# with any KV type and is refused.  sudo service llama-t0 start yarn2  (or restart yarn2)  /  YARN=2 ./llama-tier.sh t0 start
#
# Runtime files (service user): ~/local-ai-runs/llama-TIER.pid, llama-TIER.log (server log) and llama-TIER.out (stderr, a mirror
# of the log plus startup errors) - both rotated to .prev at every start; llama-tiers.history keeps one line per start/UP/stop.
# Nothing here runs at boot (rc.d KEYWORD nostart) or at shutdown.
set -u
SERVICE_USER=lgryglicki
HOST=10.253.254.1; PORT=18080; URL="http://$HOST:$PORT"
LOCAL_AI=${LOCAL_AI:-/data/local-ai}
MODELS=$LOCAL_AI/models
KEY_FILE=$LOCAL_AI/key.secret
BIN_V2=/data/ai/local-agent-poc/src/llama.cpp/build-vulkan-2/bin/llama-server                 # patched build (patches/0001+0002), validated for T0/T1
BIN_MASTER=/data/ai/local-agent-poc/src/llama.cpp-master/build-vulkan-master/bin/llama-server  # upstream master >= b10889 (Qwen3.8 arch), same patches
RUNS=${LOCAL_AI_RUNS:-/home/$SERVICE_USER/local-ai-runs}
HIST=$RUNS/llama-tiers.history

TIER=${1:-}; CMD=${2:-}; ARG=${3:-}
case "$TIER" in t0|t1|t2) ;; *) echo "usage: $0 t0|t1|t2 start|stop|status|restart [yarn2]" >&2; exit 64 ;; esac
case "$CMD" in start|stop|status|restart) ;; *) echo "usage: $0 t0|t1|t2 start|stop|status|restart [yarn2]" >&2; exit 64 ;; esac

# always run as the service user (the rc.d stub calls us as root)
if [ "$(id -un)" != "$SERVICE_USER" ]; then
  [ "$(id -u)" = 0 ] || { echo "run as $SERVICE_USER or root" >&2; exit 1; }
  exec su -l "$SERVICE_USER" -c "YARN='${YARN:-}' $(realpath "$0") $TIER $CMD $ARG"
fi
mkdir -p "$RUNS"

tier_env() {
  NP=1; CTX=262144; SPEC=none; CACHE_RAM=8192; TEMP=1.0; TOP_P=0.95; TOP_K=20; MIN_P=0.0
  KWARGS='{"enable_thinking":true}'; EFFORT=; NCMOE=0; BATCH=2048; UBATCH=1024
  case "$1" in
    t0) PROFILE=fastest-vram; MODEL=Qwen3.6-35B-A3B-UD-IQ2_M.gguf;  ALIAS=qwen3.6-35b-a3b;    TITLE='Qwen3.6-35B-A3B UD-IQ2_M'
        BIN=$BIN_V2;     NCMOE=0;  THREADS=8;  TBATCH=16 ;;
    t1) PROFILE=fast;         MODEL=Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf; ALIAS=qwen3.6-35b-a3b-q4; TITLE='Qwen3.6-35B-A3B UD-Q4_K_XL'
        BIN=$BIN_V2;     NCMOE=20; THREADS=8;  TBATCH=16 ;;
    t2) PROFILE=best;         MODEL=Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf; ALIAS=qwen3.8-flash-next; TITLE='Qwen3.8-Flash-Next UD-IQ4_XS'
        BIN=$BIN_MASTER; NCMOE=47; THREADS=16; TBATCH=16; EFFORT=xhigh ;;   # the template's levels are xhigh (default, = max) / medium / low
  esac
  PIDF=$RUNS/llama-$1.pid; LOG=$RUNS/llama-$1.log; OUT=$RUNS/llama-$1.out
}

alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }
note() { echo "$(date '+%F %T') $*" | tee -a "$HIST" >> "$OUT"; }
pid_of() { cat "$RUNS/llama-$1.pid" 2>/dev/null; }
running_tier() {   # prints the tier whose server is alive (pidfile), if any
  for t in t0 t1 t2; do p=$(pid_of "$t"); alive "$p" && { echo "$t"; return 0; }; done; return 1
}
port_pid() { sockstat -4l -p "$PORT" 2>/dev/null | awk 'NR>1 && $6 ~ /:'"$PORT"'$/ {print $3; exit}'; }
key() { cat "$KEY_FILE"; }
vram() { nvidia-smi --query-gpu=memory.used --format=csv,noheader 2>/dev/null | tr -d ' ' || echo "n/a"; }

ramp() {   # gap-free geometric load ramp 1 -> 4096 prompt tokens (4 generated each): the GPU's power step is softened after a load;
           # every AC-adapter dropout of the campaign sat on the first idle->full-power prefill (results-t1.md §6.2)
  n=1; steps=0
  while [ "$n" -le 4096 ]; do
    p=$(awk -v n="$n" 'BEGIN{for(i=0;i<n;i++) printf "%s", (i ? " x" : "x")}')
    curl -s -m 900 -H "Authorization: Bearer $(key)" -H "Content-Type: application/json" "$URL/completion" \
      -d "{\"prompt\":\"$p\",\"n_predict\":4,\"cache_prompt\":false,\"temperature\":0}" >/dev/null 2>&1 && steps=$((steps + 1))
    n=$((n * 4))
  done
  echo "soft-start: $steps/7 ramp steps (1..4096 prompt tokens)"
}

do_start() {
  tier_env "$TIER"
  yarn=${YARN:-}; case "$ARG" in yarn2|yarn=2|YARN=2) yarn=2 ;; yarn4|yarn=4|YARN=4) yarn=4 ;; "") ;; *) echo "unknown start argument '$ARG' (only: yarn2)" >&2; exit 64 ;; esac
  ROPE=; KV=q8_0
  case "$yarn" in
    "" ) ;;
    2) CTX=524288; ROPE="--rope-scaling yarn --rope-scale 2 --yarn-orig-ctx 262144"; KV=q4_0
       [ "$TIER" = t2 ] && { BATCH=1024; UBATCH=512; } ;;   # t2: the 512K prefill compute buffer needs 9.3 GiB at ubatch 1024 (load-tested) - halve it
    4) echo "yarn4 (1M ctx) refused: the KV cache for 1 048 576 tokens does not fit next to the weights in 16 GiB VRAM (T0 would need ~13.6 GiB q8_0 / ~7 GiB q4_0 for KV alone, T2 ~12.8 / ~6.8) and KV in host RAM is not an option on this box" >&2; exit 1 ;;
    *) echo "YARN must be 2 (or unset)" >&2; exit 64 ;;
  esac
  p=$(cat "$PIDF" 2>/dev/null); alive "$p" && { echo "llama-$TIER already running (pid $p) - sudo service llama-$TIER status"; exit 0; }
  rm -f "$PIDF"
  other=$(running_tier) && { echo "llama-$other is running (pid $(pid_of "$other")) and the card holds one model at a time: sudo service llama-$other stop  first" >&2; exit 1; }
  pp=$(port_pid); [ -n "$pp" ] && { echo "something else already listens on $HOST:$PORT (pid $pp, $(ps -o command= -p "$pp" | cut -c1-80)) - probably the research start.sh server: /data/local-ai/asgard/stop.sh first" >&2; exit 1; }
  [ -x "$BIN" ] || { echo "llama-server binary missing: $BIN" >&2; exit 1; }
  [ -f "$MODELS/$MODEL" ] || { echo "model file missing: $MODELS/$MODEL" >&2; exit 1; }
  [ -r "$KEY_FILE" ] || { echo "API key file missing/unreadable: $KEY_FILE" >&2; exit 1; }
  NCMOE_ARGS=; [ "$NCMOE" -gt 0 ] && NCMOE_ARGS="--n-cpu-moe $NCMOE"
  EFFORT_ARGS=; [ -n "$EFFORT" ] && EFFORT_ARGS="--reasoning-effort $EFFORT"
  [ -f "$LOG" ] && mv "$LOG" "$LOG.prev"
  [ -f "$OUT" ] && mv "$OUT" "$OUT.prev"
  note "START llama-$TIER ($PROFILE: $TITLE) ctx=$CTX ncmoe=$NCMOE threads=$THREADS/$TBATCH kv=$KV batch=$BATCH/$UBATCH${ROPE:+ $ROPE}"
  t0=$(date +%s)
  # --load-mode none = read() the model into RAM (no mmap; ~60 GiB of experts land in Vulkan pinned host memory).
  # --lazy-mode off  = 15 Sep 2026: llama.cpp's default 'auto' maps tensors flagged TENSOR_READ_LAZY anyway and fetches
  #   their rows from disk per token — for Qwen3.8-Flash-Next that is per_layer_token_embd.weight (26.8 GiB, IQ4_NL):
  #   38 page faults/s in decode, 229/s in prefill, each a 128 KB record from all 4 NVMe (models dataset is
  #   primarycache=metadata) -> steady disk traffic that kept the PCH/NVMe links awake (see asgard/ops.md 15 Sep).
  #   'off' keeps the table resident (+27 GiB RAM, we have 128) -> zero model IO after the load.
  # shellcheck disable=SC2086
  GGML_VK_VISIBLE_DEVICES=0 daemon -f -p "$PIDF" -o "$OUT" "$BIN" --model "$MODELS/$MODEL" --alias "$ALIAS,qwen3coder-local" \
    --host "$HOST" --port "$PORT" \
    --ctx-size "$CTX" --parallel "$NP" --gpu-layers 99 --device Vulkan0 --fit off $NCMOE_ARGS $ROPE \
    --flash-attn on --cache-type-k "$KV" --cache-type-v "$KV" --cache-ram "$CACHE_RAM" \
    --batch-size "$BATCH" --ubatch-size "$UBATCH" --threads "$THREADS" --threads-batch "$TBATCH" \
    --load-mode none --lazy-mode off --ctx-checkpoints 8 --no-warmup \
    --spec-type "$SPEC" \
    --jinja --reasoning on --reasoning-budget -1 --chat-template-kwargs "$KWARGS" $EFFORT_ARGS \
    --temp "$TEMP" --top-p "$TOP_P" --top-k "$TOP_K" --min-p "$MIN_P" --repeat-penalty 1.0 \
    --no-mmproj --no-ui --no-agent --offline --timeout 43200 --api-key-file "$KEY_FILE" \
    --log-file "$LOG" || { echo "daemon(8) failed to start llama-server" >&2; exit 1; }
  sleep 2
  while :; do
    curl -s -m 2 "$URL/health" 2>/dev/null | grep -q ok && break
    p=$(cat "$PIDF" 2>/dev/null)
    alive "$p" || { echo "llama-$TIER EXITED after $(( $(date +%s) - t0 )) s - last log lines:" >&2; grep -vE '^\s*$' "$LOG" 2>/dev/null | tail -12 | cut -c1-200 >&2; echo "-- stderr ($OUT):" >&2; tail -6 "$OUT" | cut -c1-200 >&2; rm -f "$PIDF"; exit 1; }
    [ $(( $(date +%s) - t0 )) -gt 1800 ] && { echo "llama-$TIER not healthy after 30 min - stopping" >&2; kill "$p"; rm -f "$PIDF"; exit 1; }
    sleep 1
  done
  echo "llama-$TIER UP in $(( $(date +%s) - t0 )) s (pid $(cat "$PIDF")) | $PROFILE: $TITLE | ctx $CTX x$NP, KV $KV${ROPE:+, YaRN x$yarn}, experts in RAM: $NCMOE, threads $THREADS/$TBATCH | VRAM $(vram) | $URL"
  [ "${SOFTSTART:-1}" != 0 ] && ramp
  [ "$TIER" = t1 ] && [ -n "$ROPE" ] && echo "note: t1 yarn2 peaks at ~16.0 of 16.4 GiB VRAM while loading (15.0 steady, load test 15 Sep) - tight; if a start ever fails with 'failed to allocate Vulkan0 buffer', use t0 or t2 for 512K work"
  note "UP    llama-$TIER pid $(cat "$PIDF") ctx=$CTX kv=$KV vram=$(vram)"
}

do_stop() {
  tier_env "$TIER"
  p=$(cat "$PIDF" 2>/dev/null)
  alive "$p" || { rm -f "$PIDF"; if o=$(running_tier); then echo "llama-$TIER is not running (llama-$o is, pid $(pid_of "$o"))"; else echo "llama-$TIER is not running"; fi; return 0; }
  kill "$p"
  for i in $(seq 1 30); do alive "$p" || break; sleep 1; done
  alive "$p" && { echo "still alive after 30 s, sending KILL"; kill -9 "$p"; sleep 2; }
  rm -f "$PIDF"
  note "STOP  llama-$TIER pid $p"
  echo "llama-$TIER stopped (pid $p) | VRAM now $(vram)"
}

do_status() {
  tier_env "$TIER"
  p=$(cat "$PIDF" 2>/dev/null)
  if alive "$p"; then
    h=$(curl -s -m 3 "$URL/health" 2>/dev/null | tr -d '\n' | cut -c1-40); [ -n "$h" ] || h="no answer on $URL/health"
    m=$(curl -s -m 3 -H "Authorization: Bearer $(key)" "$URL/v1/models" 2>/dev/null | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -1)
    n=$(curl -s -m 3 -H "Authorization: Bearer $(key)" "$URL/props" 2>/dev/null | sed -n 's/.*"n_ctx":\([0-9]*\).*/\1/p' | head -1)
    since=$(ps -o lstart= -p "$p" 2>/dev/null | sed 's/^ *//')
    busy=$(curl -s -m 3 -H "Authorization: Bearer $(key)" "$URL/slots" 2>/dev/null | grep -o '"is_processing":[a-z]*' | head -1 | sed 's/"is_processing"://; s/true/busy/; s/false/idle/')
    echo "llama-$TIER is running: pid $p since $since | $PROFILE: $TITLE | served model id: ${m:-?} | ctx ${n:-?} | slot ${busy:-?} | health: $h | VRAM $(vram) | $URL | log $LOG"
    return 0
  fi
  [ -n "$p" ] && rm -f "$PIDF"
  if o=$(running_tier); then echo "llama-$TIER is not running (llama-$o is, pid $(pid_of "$o") - one tier at a time)"
  elif pp=$(port_pid) && [ -n "$pp" ]; then echo "llama-$TIER is not running; another llama-server (pid $pp, not a tier service) listens on $HOST:$PORT"
  else echo "llama-$TIER is not running (no tier service is; GPU VRAM used: $(vram))"; fi
  return 1
}

case "$CMD" in
  start) do_start ;;
  stop) do_stop ;;
  status) do_status ;;
  restart) do_stop; do_start ;;
esac
