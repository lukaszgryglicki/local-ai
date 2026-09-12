#!/bin/sh
# /data/local-ai/asgard/zzz-probe.sh pre|task|zzz|post [TAG] - does the RUNNING llama-server (weights + KV cache in
# Quadro VRAM, Vulkan) survive an ACPI S3 suspend/resume? Owner-driven: the resume needs someone at the laptop.
#   pre  [TAG]  record state (server pid, VRAM, slot) + a deterministic reference answer (temperature 0, top_k 1,
#               cache_prompt off, so the text depends only on the weights) -> ~/local-ai-runs/zzz/TAG-pre.{state,json,txt}
#   task [TAG]  start a small headless qwen-code task (detached, /data/ai/zzz-task-MODEL) and wait until the server is
#               generating for it - the suspend then hits a live GPU job, which is what the thermal watchdog would do
#   zzz         sudo zzz (S3), detached so this ssh session returns before the box sleeps
#   post [TAG]  after resume: same pid?, dmesg resume lines, /health, the same deterministic answer -> TAG-post.*, byte
#               diff against TAG-pre.txt (identical = VRAM content survived S3), and what happened to the small task
# Do not run pre/task while an E2E task is in flight: with --parallel 1 any request evicts that task's KV cache.
# Typical: ./zzz-probe.sh pre && ./zzz-probe.sh task && ./zzz-probe.sh zzz   ... owner resumes ...   ./zzz-probe.sh post
d=$(dirname "$(realpath "$0")"); u=http://10.253.254.1:18080; k=$(cat "$d/../key.secret")
M=${MODEL:-qwen9b}; R=${LOCAL_AI_RUNS:-$HOME/local-ai-runs}/zzz; TAG=${2:-$(date +%Y%m%d)}; mkdir -p "$R"
Q='In four short sentences, explain what ACPI S3 suspend-to-RAM does to the CPU, the RAM, a discrete GPU and the disks of a laptop.'

slot() { curl -s -m 5 -H "Authorization: Bearer $k" "$u/slots" | python3 -c '
import json, sys
for s in json.load(sys.stdin):
    nt = s.get("next_token", {})
    print("slot %s: processing=%s n_ctx=%s decoded=%s remain=%s" % (s.get("id"), s.get("is_processing"), s.get("n_ctx"), nt.get("n_decoded"), nt.get("n_remain")))' 2>/dev/null; }
state() {
  echo "time: $(date '+%F %T')  uptime: $(uptime | sed 's/.*up //;s/,.*//')  boottime: $(sysctl -n kern.boottime | cut -c1-30)"
  echo "llama-server pid: $(pgrep -f 'bin/llama-server' | tr '\n' ' ')  gpu(mem.used,temp,util): $(nvidia-smi --query-gpu=memory.used,temperature.gpu,utilization.gpu --format=csv,noheader)"
  echo "acline: $(sysctl -n hw.acpi.acline)  batt: $(sysctl -n hw.acpi.battery.life)%  health: $(curl -s -m 5 "$u/health")"
  slot
}
ref() {  # $1 = pre|post
  curl -s -m 900 "$u/v1/chat/completions" -H "Authorization: Bearer $k" -H "Content-Type: application/json" \
    -d "{\"model\":\"qwen3coder-local\",\"messages\":[{\"role\":\"user\",\"content\":\"$Q\"}],\"max_tokens\":192,\"temperature\":0,\"top_k\":1,\"seed\":7,\"cache_prompt\":false}" > "$R/$TAG-$1.json"
  python3 - "$R/$TAG-$1.json" "$R/$TAG-$1.txt" <<'EOF'
import json, sys
r = json.load(open(sys.argv[1])); m = r["choices"][0]["message"]; t = r.get("timings", {})
open(sys.argv[2], "w").write("[reasoning]\n%s\n[content]\n%s\n" % (m.get("reasoning_content") or "", m.get("content") or ""))
print("reference answer: %d reasoning + %d content chars, finish=%s | pp %.0f t/s, tg %.1f t/s (%s tokens)" % (
    len(m.get("reasoning_content") or ""), len(m.get("content") or ""), r["choices"][0].get("finish_reason"),
    t.get("prompt_per_second", 0), t.get("predicted_per_second", 0), t.get("predicted_n", "?")))
EOF
}

case ${1:-} in
  pre)
    state | tee "$R/$TAG-pre.state"; ref pre | tee -a "$R/$TAG-pre.state"; echo "saved: $R/$TAG-pre.*" ;;
  task)
    W=/data/ai/zzz-task-$M; [ -d "$W" ] && mv "$W" "$W.prev-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$W"; cd "$W" || exit 1
    P='Write a Python 3 script fib.py that prints the first 60 Fibonacci numbers one per line, run it with python3, then tell me the last three lines it printed.'
    MODEL=$M daemon -f -p "$W/qwen.pid" -o "$W/qwen.log" timeout 3600 "$d/qwen.sh" --yolo -o stream-json "$P"
    echo "$(date +%T) small task started in $W (pid $(cat "$W/qwen.pid" 2>/dev/null)), waiting for generation..."
    i=0; while [ $i -lt 90 ]; do
      s=$(slot); case $s in *processing=True*) n=${s##*decoded=}; n=${n%% *}; [ "${n:-0}" -ge 30 ] 2>/dev/null && break ;; esac
      sleep 2; i=$((i + 1)); done
    echo "$(date +%T) $s"; tail -1 "${LOCAL_AI_RUNS:-$HOME/local-ai-runs}/llama.log" | cut -c1-160
    nvidia-smi --query-gpu=utilization.gpu,power.draw,temperature.gpu --format=csv,noheader ;;
  zzz)
    echo "$(date '+%F %T') suspending (S3) with the server up: $(slot)"; sudo daemon -f /usr/sbin/zzz; echo "zzz issued" ;;
  post)
    state | tee "$R/$TAG-post.state"
    echo "-- pre state was:"; sed -n '1,2p' "$R/$TAG-pre.state" 2>/dev/null
    echo "-- dmesg (resume/nvidia/acpi, last lines):"; dmesg | grep -i -E "wakeup|resume|nvidia|acpi_(timer|lid|button)|suspend" | tail -8 | cut -c1-140
    echo "-- thermal.log tail:"; tail -3 /var/log/thermal.log 2>/dev/null | cut -c1-140
    W=/data/ai/zzz-task-$M
    echo "-- small task: $( [ -f "$W/qwen.pid" ] && kill -0 "$(cat "$W/qwen.pid")" 2>/dev/null && echo still running || echo finished ), fib.py $( [ -f "$W/fib.py" ] && echo present || echo missing ), $(grep -c '"type":"assistant"' "$W/qwen.log" 2>/dev/null) assistant turns, $(grep -o '"name":"[a-z_]*"' "$W/qwen.log" 2>/dev/null | wc -l | tr -d ' ') tool calls"
    grep -o '"type":"result"[^}]\{0,300\}' "$W/qwen.log" 2>/dev/null | tail -1 | cut -c1-300
    ref post | tee -a "$R/$TAG-post.state"
    if cmp -s "$R/$TAG-pre.txt" "$R/$TAG-post.txt"; then echo "VERDICT: deterministic answer IDENTICAL before/after S3 - VRAM content survived"
    else echo "VERDICT: deterministic answer DIFFERS after S3 (see diff below) - VRAM state not intact"; diff "$R/$TAG-pre.txt" "$R/$TAG-post.txt" | head -20; fi | tee -a "$R/$TAG-post.state" ;;
  *) sed -n '2,12p' "$0"; exit 1 ;;
esac
