#!/bin/sh
# /data/local-ai/asgard/e2e-test.sh MODEL TASK - one E2E coding task (rust|go|c|asm, see e2e-tasks.sh) for the model
# the server is RUNNING (MODEL must match asgard/serve.sh's model): drive asgard/qwen.sh headless (--yolo, thinking on,
# the model's own sampling) with the task prompt (+ task input on stdin for asm), then verify the result independently
# with verify-TASK.sh (fresh build, tests, byte-exact comparisons against Python references) and pull the server-side
# speed numbers (prompt/generation tokens and t/s per request, spec-decoding acceptance, context depth) from the llama
# log slice written during the run.
# Output (preserved): /data/ai/TASK-task-MODEL/{qwen.log,health.txt,summary.txt,per-request.txt,+ the model's project};
# a previous run is kept as /data/ai/TASK-task-MODEL.prev-<timestamp>. summary.txt is also printed.
# Self-healing: when qwen ends with an "[API Error ...]" result (server killed/restarted, S3 hang, connection reset) the
# run is NOT over - the harness waits for /health (E2E_WAIT_UP, default 1800 s), then continues the same session with
# qwen -r SESSION-ID (qwen -c if the id is not in the log) and a short nudge (RESUME_PROMPT), up to E2E_RESUMES (3)
# times; output is appended to qwen.log, resume.log lists the events, the summary header shows resumes= and the
# downtime (wall includes it). If the server log was rotated by asgard/start.sh meanwhile, the timing slice spans
# llama.log.prev + llama.log. RESUME=SESSION-UUID e2e-test.sh MODEL TASK does the same by hand after the harness
# itself died (crash, reboot): existing directory, previous summary/per-request kept as *.prev-<timestamp>.
# asgard/unstick.sh watch runs alongside the task (E2E_UNSTICK=0 disables): a server whose GPU work will never finish
# (S3 suspend with a request in flight) is killed and restarted with start.sh --last, which turns the silent hang into
# the API error above and therefore into a resume.
d=$(dirname "$(realpath "$0")")
M=${1:-north}; T=${2:-rust}
. "$d/e2e-tasks.sh"
PROMPT=$(e2e_prompt "$T") || exit 1
W=/data/ai/$T-task-$M
RUNS=${LOCAL_AI_RUNS:-$HOME/local-ai-runs}
LOG=${LOG:-$RUNS/llama.log}
QARGS=""
if [ -n "${RESUME:-}" ]; then
  cd "$W" 2>/dev/null || { echo "nothing to resume in $W"; exit 1; }
  ts=$(date +%Y%m%d-%H%M%S); for f in summary per-request; do [ -f $f.txt ] && mv $f.txt "$f.prev-$ts.txt"; done
  PROMPT=${RESUME_PROMPT:-"The model server was restarted and your last request failed with a connection error; nothing on disk was lost. Continue the original task exactly where you left off."}
  QARGS="-r $RESUME"; STDIN=/dev/null
else
  [ -d "$W" ] && mv "$W" "$W.prev-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$W"; cd "$W" || exit 1
fi
"$d/health.sh" > health.txt 2>&1 || { cat health.txt; echo "server not healthy - aborting"; exit 1; }
[ -n "$QARGS" ] || { STDIN=$(e2e_prepare "$T" "$W") || { echo "task preparation failed"; exit 1; }; }
[ -n "$STDIN" ] || STDIN=/dev/null
off=$(stat -f %z "$LOG" 2>/dev/null || echo 0); ino=$(stat -f %i "$LOG" 2>/dev/null || echo 0); slices="$LOG:$off"
NUDGE=${RESUME_PROMPT:-"The model server was restarted and your last request failed with a connection error; nothing on disk was lost. Continue the original task exactly where you left off."}
last_result() { grep '"type":"result"' qwen.log | tail -1; }
api_error() { last_result | grep -q '"result":"\[API Error'; }
t0=$(date +%s); resumes=0; downtime=0
[ "${E2E_UNSTICK:-1}" = 0 ] || { "$d/unstick.sh" watch 30 >> unstick.log 2>&1 & UW=$!; }
MODEL=$M timeout 14400 "$d/qwen.sh" --yolo -o stream-json $QARGS "$PROMPT" < "$STDIN" >> qwen.log 2>&1
rc=$?
while [ "$resumes" -lt "${E2E_RESUMES:-3}" ] && api_error; do   # self-heal: wait for the server, continue the session
  resumes=$((resumes + 1)); td=$(date +%s); sid=$(last_result | sed -n 's/.*"session_id":"\([0-9a-f-]*\)".*/\1/p')
  echo "$(date '+%F %T') resume $resumes: $(last_result | sed -n 's/.*"result":"\(\[API Error[^"]\{0,120\}\).*/\1/p') - waiting for the server (max ${E2E_WAIT_UP:-1800} s)" >> resume.log
  up() { curl -s -m 5 http://10.253.254.1:18080/health 2>/dev/null | grep -q '"ok"'; }   # /health only: no request, keeps a live KV cache
  w=0; until up; do sleep 30; w=$((w + 30)); [ "$w" -ge "${E2E_WAIT_UP:-1800}" ] && break; done
  downtime=$((downtime + $(date +%s) - td))
  up || { echo "$(date '+%F %T') server still down after $w s - giving up" >> resume.log; break; }
  if [ "$(stat -f %i "$LOG" 2>/dev/null)" != "$ino" ]; then slices="$LOG.prev:$off $LOG:0"; ino=$(stat -f %i "$LOG"); off=0; fi   # log rotated by start.sh
  echo "$(date '+%F %T') server back after $(($(date +%s) - td)) s, qwen ${sid:+-r $sid}${sid:--c}" >> resume.log
  MODEL=$M timeout 14400 "$d/qwen.sh" --yolo -o stream-json ${sid:+-r "$sid"} ${sid:--c} "$NUDGE" < /dev/null >> qwen.log 2>&1
  rc=$?
done
t1=$(date +%s); [ -n "${UW:-}" ] && kill "$UW" 2>/dev/null
{
echo "== e2e-test $M $T ${RESUME:+(resumed $RESUME) } $(date)  qwen rc=$rc  wall=$((t1 - t0)) s  stdin=$( [ "$STDIN" = /dev/null ] && echo none || wc -c < "$STDIN" | tr -d ' ' ) bytes  resumes=$resumes downtime=$downtime s"
[ -f resume.log ] && sed 's/^/  /' resume.log; [ -s unstick.log ] && grep STUCK unstick.log | sed 's/^/  unstick: /'
cat health.txt
echo "== server-side timings for this run (log slice):"
python3 - "$slices" per-request.txt <<'EOF'
import re, sys
data = ""
for part in sys.argv[1].split():   # "file:offset ..." - more than one when the server log was rotated during the run
    f, o = part.rsplit(":", 1)
    try: data += open(f, "rb").read()[int(o):].decode("utf-8", "replace")
    except OSError as e: print("cannot read log slice %s: %s" % (part, e))
reqs = re.findall(r"task (\d+) \| prompt eval time =\s*([\d.]+) ms /\s*(\d+) tokens.*?\n.*?\|\s*eval time =\s*([\d.]+) ms /\s*(\d+) tokens"
                  r"(?:.*?\n(?:.*?draft acceptance = ([\d.]+) \(\s*(\d+) accepted /\s*(\d+) generated)?)?.*?stop processing: n_tokens =\s*(\d+)", data, re.S)
if not reqs:
    print("no timing lines found in log slice (%d bytes)" % len(data))
else:
    pn = sum(int(r[2]) for r in reqs); pms = sum(float(r[1]) for r in reqs)
    gn = sum(int(r[4]) for r in reqs); gms = sum(float(r[3]) for r in reqs)
    rates = [int(r[4]) / float(r[3]) * 1000 for r in reqs if float(r[3]) > 0 and int(r[4]) >= 16]
    long_ = [(float(r[3]), int(r[4])) for r in reqs if int(r[4]) >= 200]
    big = [(float(r[1]), int(r[2])) for r in reqs if int(r[2]) >= 1000]
    print("requests: %d | prompt tokens: %d in %.1f s (%.0f t/s aggregate) | generated: %d in %.1f s (%.1f t/s aggregate; per-request tg min %.1f / max %.1f)" % (
        len(reqs), pn, pms / 1000, pn / pms * 1000 if pms else 0, gn, gms / 1000, gn / gms * 1000 if gms else 0,
        min(rates) if rates else 0, max(rates) if rates else 0))
    if big: print("prompt batches >= 1000 tokens: %d, pp %.0f t/s aggregate (%s)" % (len(big), sum(b for _, b in big) / sum(a for a, _ in big) * 1000, ", ".join("%d tok @ %.0f t/s" % (b, b / a * 1000) for a, b in big)))
    if long_: print("answers >= 200 tokens: %d, tg %.1f t/s aggregate" % (len(long_), sum(b for _, b in long_) / sum(a for a, _ in long_) * 1000))
    print("context depth per request: first %s, max %s tokens" % (reqs[0][8], max(int(r[8]) for r in reqs)))
    acc = [(int(r[6]), int(r[7])) for r in reqs if r[6]]
    if acc:
        a = sum(x for x, _ in acc); g = sum(y for _, y in acc)
        print("speculative: %d drafted, %d accepted (%.1f%%) over %d requests with drafts" % (g, a, 100 * a / g if g else 0, len(acc)))
    with open(sys.argv[2], "w") as f:
        f.write("req  ctx_tokens  pp_tok  pp_t/s  gen_tok  tg_t/s  draft_acc\n")
        for i, r in enumerate(reqs):
            f.write("%3d %10s %7s %7.0f %8s %7.1f  %s\n" % (i, r[8], r[2], int(r[2]) / float(r[1]) * 1000 if float(r[1]) else 0, r[4],
                    int(r[4]) / float(r[3]) * 1000 if float(r[3]) else 0, ("%s/%s" % (r[6], r[7])) if r[6] else "-"))
for m in re.findall(r"(?i)(out of memory|device ?lost|VK_ERROR[A-Z_]*|abort|assert[^\n]*|context shift|truncated = 1|n_ctx_slot exceeded|exceeds)", data)[:5]:
    print("ANOMALY:", m)
EOF
echo "== qwen stream summary:"
python3 - qwen.log <<'EOF'
import json, sys
tools = {}; turns = None; result = None; errs = []; usage = None; dur = None; tool_errs = 0
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line.startswith("{"):
        if line and "warn" not in line.lower(): errs.append(line[:160])
        continue
    try: ev = json.loads(line)
    except ValueError: continue
    if ev.get("type") == "result":
        turns = ev.get("num_turns"); result = ev.get("subtype"); dur = ev.get("duration_ms"); usage = ev.get("usage")
    msg = ev.get("message") or {}
    for c in msg.get("content") or []:
        if isinstance(c, dict):
            if c.get("type") == "tool_use": tools[c.get("name")] = tools.get(c.get("name"), 0) + 1
            if c.get("type") == "tool_result" and c.get("is_error"): tool_errs += 1
print("result: %s | turns: %s | duration: %s s | tool calls: %s | tool errors: %d" % (result, turns, (dur or 0) // 1000, tools or "none", tool_errs))
if usage: print("usage: input %s (cache read %s), output %s tokens" % (usage.get("input_tokens"), usage.get("cache_read_input_tokens"), usage.get("output_tokens")))
for e in errs[:5]: print("non-json line:", e)
EOF
echo "== independent verification (verify-$T.sh):"
"$d/verify-$T.sh" .
} | tee summary.txt
