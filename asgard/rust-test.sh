#!/bin/sh
# /data/local-ai/asgard/rust-test.sh MODEL - the "full test" for one served model: drive asgard/qwen.sh
# headless (--yolo) against the RUNNING server to write, build and unit-test a Rust string reverser,
# then verify the result independently (fresh cargo build/test, stdin round-trips vs Python's s[::-1])
# and pull server-side speed numbers (pp/tg per request, draft acceptance) from the llama log slice
# written during the run. MODEL must match asgard/serve.sh's model.
# Output (preserved): /data/ai/rust-task-MODEL/{qwen.log,health.txt,summary.txt, revstr/ or Cargo.toml+src/}; a previous run is
# kept as /data/ai/rust-task-MODEL.prev-<timestamp>. Summary also on stdout.
d=$(dirname "$(realpath "$0")")
M=${1:-north}
W=/data/ai/rust-task-$M
RUNS=${LOCAL_AI_RUNS:-$HOME/local-ai-runs}
LOG=${LOG:-$RUNS/llama.log}
PROMPT='Create a Rust cargo project named revstr in the current directory (write Cargo.toml and src/main.rs yourself or use cargo new). Implement pub fn reverse(s: &str) -> String that reverses a string by Unicode scalar values (chars), not bytes, and a main() that reads all of stdin, strips one trailing newline, and prints the reversed string followed by a newline. Add unit tests for: the empty string, "hello" -> "olleh", the Polish string "Zażółć gęślą jaźń", and an emoji string. No external crates. Run `cargo build --release` and `cargo test` and fix any errors until both pass. Finish by printing the final src/main.rs.'
[ -d "$W" ] && mv "$W" "$W.prev-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$W"; cd "$W" || exit 1
"$d/health.sh" > health.txt 2>&1 || { cat health.txt; echo "server not healthy - aborting"; exit 1; }
off=$(stat -f %z "$LOG" 2>/dev/null || echo 0)
t0=$(date +%s)
MODEL=$M timeout 7200 "$d/qwen.sh" --yolo -o stream-json "$PROMPT" > qwen.log 2>&1
rc=$?
t1=$(date +%s)
{
echo "== rust-test $M  $(date)  qwen rc=$rc  wall=$((t1 - t0)) s"
cat health.txt
echo "== server-side timings for this run (log slice):"
python3 - "$LOG" "$off" <<'EOF'
import re, sys
data = open(sys.argv[1], "rb").read()[int(sys.argv[2]):].decode("utf-8", "replace")
pp = [(float(a), int(b)) for a, b in re.findall(r"prompt eval time =\s*([\d.]+) ms /\s*(\d+) tokens", data)]
tg = [(float(a), int(b)) for a, b in re.findall(r"\|\s*eval time =\s*([\d.]+) ms /\s*(\d+) tokens", data)]
acc = re.findall(r"draft acceptance\s*=\s*([\d.]+) \(\s*(\d+) accepted /\s*(\d+) generated", data)
n = len(tg)
if n:
    pms = sum(a for a, _ in pp); pn = sum(b for _, b in pp)
    gms = sum(a for a, _ in tg); gn = sum(b for _, b in tg)
    rates = [b / a * 1000 for a, b in tg if a > 0 and b >= 16]
    long = [(a, b) for a, b in tg if b >= 200]
    print("requests: %d | prompt tokens: %d in %.1f s (%.0f t/s aggregate) | generated: %d in %.1f s (%.1f t/s aggregate; per-request tg min %.1f / max %.1f)" % (
        n, pn, pms / 1000, pn / pms * 1000 if pms else 0, gn, gms / 1000, gn / gms * 1000 if gms else 0,
        min(rates) if rates else 0, max(rates) if rates else 0))
    if long:
        print("answers >= 200 tokens: %d, tg %.1f t/s aggregate" % (len(long), sum(b for _, b in long) / sum(a for a, _ in long) * 1000))
    ctx = re.findall(r"stop processing: n_tokens =\s*(\d+)", data)
    if ctx: print("context depth per request: first %s, last %s tokens" % (ctx[0], ctx[-1]))
    if acc:
        a = sum(int(x[1]) for x in acc); g = sum(int(x[2]) for x in acc)
        print("speculative: %d drafted, %d accepted (%.1f%%)" % (g, a, 100 * a / g if g else 0))
else:
    print("no timing lines found in log slice (%d bytes)" % len(data))
for m in re.findall(r"(?i)(out of memory|device ?lost|VK_ERROR[A-Z_]*|abort|assert[^\n]*)", data)[:5]:
    print("ANOMALY:", m)
EOF
echo "== qwen stream summary:"
python3 - qwen.log <<'EOF'
import json, sys
tools = {}; texts = 0; errs = []; usage = None
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line.startswith("{"):
        if line and "warn" not in line.lower(): errs.append(line[:160])
        continue
    try: ev = json.loads(line)
    except ValueError: continue
    t = ev.get("type") or ev.get("event") or ""
    s = json.dumps(ev)
    for k in ("run_shell_command", "write_file", "edit", "read_file", "list_directory", "glob", "grep", "replace"):
        if '"' + k + '"' in s: tools[k] = tools.get(k, 0) + 1
    if "usage" in ev and isinstance(ev["usage"], dict): usage = ev["usage"]
    if t in ("assistant", "message", "content") or "text" in ev: texts += 1
print("tool mentions:", tools or "none", "| text events:", texts, "| usage:", usage or "n/a")
for e in errs[:5]: print("non-json line:", e)
EOF
echo "== independent verification (rust-verify.sh):"
"$d/rust-verify.sh" .
} | tee summary.txt
