#!/bin/sh
# verify-staging.sh old|new [f16|q8_0] - reproduce / verify the ">= 256 MiB pinned staging" llama-server abort
# (results-t1.md "FAIL-infra 12:21 + 12:43") on a SIDE server (port 18082 (SIDE_PORT)), never while an E2E task runs (it is a full
# qwen9b server: ~15 GiB VRAM; qwen9b was removed on 13 Sep when T-1 froze - re-add its models.sh entry from git history or set MODEL=). Flow = the 12:43 crash: fresh server, one long chat prompt (~135K tokens, many user
# turns -> context checkpoints at user-message starts), short answer, then a follow-up request that appends to the same
# context (checkpoint over the whole contiguous range). Draft KV f16 (2 KiB/token) unless given; the sysmem flag unset.
#   old = build-vulkan   (unpatched) -> expected: SIGABRT "Memory allocation of size ... failed" at >= 131 072 tokens
#   new = build-vulkan-2 (patches/0001-vulkan-chunk-staging-transfers.patch) -> expected: both answers, and
#         GGML_VK_STAGING_LOG lines showing the staging buffer never grows past GGML_VK_STAGING_CHUNK_MB (64 MiB)
# Output: ~/local-ai-runs/vt/staging-<tag>.{out,log,json}; prints a one-line verdict.
# Knobs: N_TOKENS (prompt size, default 136000), GEN1 (max_tokens of request 1; >8 asks for a long report - mirrors the
#   12:34 flow with its 1.4K-token answer), N2 (extra entries padding the follow-up, ~28 tok each), SIDE_PORT, EXTRA
#   (serve.sh, e.g. "-lv 5": ggml INFO lines such as the staging log are only visible at verbosity 5),
#   GGML_VK_STAGING_CHUNK_MB (new build only; 100000 = chunking off -> old behaviour but with the staging log).
set -u
SIDE_PORT=${SIDE_PORT:-18082}
d=$(dirname "$(realpath "$0")"); which=${1:-new}; DK=${2:-f16}
SRC=/data/ai/local-agent-poc/src/llama.cpp
case $which in old) BIN=$SRC/build-vulkan/bin/llama-server ;; new) BIN=$SRC/build-vulkan-2/bin/llama-server ;; *) echo "usage: $0 old|new [f16|q8_0]"; exit 2 ;; esac
[ -x "$BIN" ] || { echo "no $BIN"; exit 2; }
sockstat -4l -p 18080 | grep -q llama && { echo "a server is on :18080 - refusing (E2E may be running)"; exit 2; }
sockstat -4l -p ${SIDE_PORT:-18082} | grep -q llama && { echo "a server is on :${SIDE_PORT:-18082} already"; exit 2; }
VT=${LOCAL_AI_RUNS:-$HOME/local-ai-runs}/vt; mkdir -p "$VT"; tag=$which-$DK-$(date +%H%M%S)
OUT=$VT/staging-$tag.out; LOG=$VT/staging-$tag.log; URL=http://10.253.254.1:${SIDE_PORT:-18082}; KEY=$(cat "$d/../key.secret")
N=${N_TOKENS:-136000}; GEN1=${GEN1:-8}; N2=${N2:-0}
# ---- prompt: pseudo-random prose so the token count is predictable (~1.35 tok/word), ~4.4K tokens per user turn
python3 - "$N" "$VT/staging-$tag.json" "$GEN1" <<'PY'
import json, random, sys
n_tok, path, gen1 = int(sys.argv[1]), sys.argv[2], int(sys.argv[3])
random.seed(7)
W = ("ledger crate copper harbour tally river winter granite meadow signal lantern orchard furnace pillar saddle "
     "compass quarry thistle beacon canvas ember glacier hollow kestrel mortar nectar oyster paddock quiver ripple "
     "sable tundra umber vellum walnut yonder zephyr anchor bramble cinder drift").split()
TPE = 27.7   # tokens per entry, calibrated 12 Sep from a 400 exceed_context_size_error (2 820 462 tok / 101 760 entries)
def para(entries):
    out=[]
    for _ in range(entries):
        k=random.randint(6,14); s=" ".join(random.choice(W) for _ in range(k))
        out.append(f"Entry {random.randint(1000,99999)}: {s} ({random.randint(1,999)} units).")
    return " ".join(out)
msgs=[{"role":"system","content":"You are a terse assistant. Answer with at most three words."}]
tok=0; turn=0
while tok < n_tok:
    u = para(150)    # ~4.2K tokens
    a = f"Noted turn {turn}: " + para(8)
    msgs.append({"role":"user","content":f"Log turn {turn}. Remember the phrase 'copper harbour {turn}'. " + u})
    msgs.append({"role":"assistant","content":a})
    tok += int((150+8)*TPE) + 30; turn += 1
if gen1 > 8:
    msgs.append({"role":"user","content":"Write a very long, detailed report (at least 1500 words) summarising the entries above turn by turn. Do not stop early."})
else:
    msgs.append({"role":"user","content":"Reply with exactly the word OK and nothing else."})
json.dump({"messages":msgs,"max_tokens":gen1,"temperature":0,"stream":False}, open(path,"w"))
print(f"prompt: {turn} turns, ~{tok} tokens estimated")
PY
# ---- server
echo "=== $(date '+%F %T') verify-staging $which DK=$DK bin=$BIN" | tee "$OUT"
( unset GGML_VK_ALLOW_SYSMEM_FALLBACK; cd "$d" && NP=1 PORT=$SIDE_PORT B=$BIN DRAFT_KV=$DK GGML_VK_STAGING_LOG=1 LOG=$LOG \
    exec ./serve.sh "${MODEL:-qwen9b}" >>"$OUT" 2>&1 ) & SPID=$!
i=0; while [ $i -lt 120 ]; do curl -sf -m 2 -o /dev/null "$URL/health" && break; kill -0 $SPID 2>/dev/null || break; sleep 1; i=$((i+1)); done
if ! curl -sf -m 2 -o /dev/null "$URL/health"; then echo "server did not come up (see $OUT)"; tail -n 5 "$OUT"; exit 1; fi
pid=$(sockstat -4l -p ${SIDE_PORT:-18082} | awk 'NR>1 && /llama/ {print $3; exit}')
echo "server pid $pid up after $i s, VRAM $(nvidia-smi --query-gpu=memory.used --format=csv,noheader)" | tee -a "$OUT"
t0=$(date +%s)
r1=$(curl -s -m 3000 -w '\nHTTP %{http_code}' -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
     --data-binary @"$VT/staging-$tag.json" "$URL/v1/chat/completions")
t1=$(date +%s); echo "request 1: $((t1-t0)) s: $(printf '%s' "$r1" | tail -c 400 | tr '\n' ' ')" | tee -a "$OUT"
alive=1; kill -0 "$pid" 2>/dev/null || alive=0
if [ $alive = 1 ]; then
  # follow-up on the same context (the 12:43 pattern: checkpoint at a user start over the whole range)
  a1=$(printf '%s' "$r1" | python3 -c 'import json,sys; d=sys.stdin.read(); d=d[:d.rfind("HTTP")]; print(json.loads(d)["choices"][0]["message"]["content"])' 2>/dev/null || echo OK)
  python3 - "$VT/staging-$tag.json" "$N2" "$a1" <<'PY'
import json, sys, random
p=sys.argv[1]; n2=int(sys.argv[2]); a1=sys.argv[3]; b=json.load(open(p)); random.seed(11)
W="ledger crate copper harbour tally river winter granite meadow signal lantern orchard furnace pillar saddle".split()
pad=" ".join(f"Entry {random.randint(1000,99999)}: {' '.join(random.choice(W) for _ in range(random.randint(6,14)))} ({random.randint(1,999)} units)." for _ in range(n2))
b["messages"].append({"role":"assistant","content":a1})
b["messages"].append({"role":"user","content":"Which phrase did I ask you to remember in turn 3? Answer with the phrase only. " + pad})
b["max_tokens"]=16; json.dump(b, open(p,"w"))
PY
  t2=$(date +%s)
  r2=$(curl -s -m 3000 -w '\nHTTP %{http_code}' -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
       --data-binary @"$VT/staging-$tag.json" "$URL/v1/chat/completions")
  t3=$(date +%s); echo "request 2: $((t3-t2)) s: $(printf '%s' "$r2" | tail -c 400 | tr '\n' ' ')" | tee -a "$OUT"
  kill -0 "$pid" 2>/dev/null || alive=0
fi
sleep 1
echo "--- staging growth / allocation lines:" | tee -a "$OUT"
grep -h "sync staging buffer\|Memory allocation of size\|ErrorOutOfDeviceMemory\|Terminating\|GGML_ASSERT" "$OUT" "$LOG" 2>/dev/null | grep -v "^===\|^---" | sort | uniq -c | tee -a "$OUT"
grep -h "prompt eval time\|n_tokens = " "$LOG" 2>/dev/null | grep "prompt eval time\|stop processing" | tail -n 4 | cut -c1-140 | tee -a "$OUT"
if [ $alive = 1 ]; then kill "$pid" 2>/dev/null; i=0; while kill -0 "$pid" 2>/dev/null && [ $i -lt 30 ]; do sleep 1; i=$((i+1)); done; kill -9 "$pid" 2>/dev/null; fi
crashed=$(dmesg | grep -c "pid $pid (llama-server).*exited on signal")
echo "VERDICT $which DK=$DK: server_alive_after_both_requests=$alive kernel_crash_lines=$crashed | $OUT" | tee -a "$OUT"
