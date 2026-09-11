#!/bin/sh
# /data/local-ai/asgard/health.sh - is the asgard server up, which model/slots, is it generating
# (and thinking)? Same endpoint as ../health.sh; adds /props and reasoning_content + timings.
d=$(dirname "$(realpath "$0")")
u=http://10.253.254.1:18080
k=$(cat "$d/../key.secret")
h=$(curl -s -m 5 "$u/health") || { echo "DOWN: no answer on $u/health"; exit 1; }
echo "$h" | grep -q ok || { echo "UNHEALTHY: $h"; exit 1; }
curl -s -m 5 -H "Authorization: Bearer $k" "$u/props" | python3 -c '
import json, sys
p = json.load(sys.stdin); g = p.get("default_generation_settings", {})
print("model: %s | slots: %s | n_ctx per slot: %s | %s" % (
    str(p.get("model_path", "?")).rsplit("/", 1)[-1], p.get("total_slots"), g.get("n_ctx"),
    str(p.get("build_info", "?"))[:40]))'
r=$(curl -s -m 900 "$u/v1/chat/completions" -H "Authorization: Bearer $k" -H "Content-Type: application/json" \
  -d '{"model":"qwen3coder-local","messages":[{"role":"user","content":"Reply with exactly: OK"}],"max_tokens":2048,"temperature":0}')
echo "$r" | grep -q '"content"' || { echo "SERVED BUT NOT GENERATING: $r"; exit 1; }
echo "$r" | python3 -c '
import json, sys
r = json.load(sys.stdin); m = r["choices"][0]["message"]; t = r.get("timings", {})
print("HEALTHY: content=%r | reasoning_content=%d chars | pp %.0f t/s, tg %.1f t/s (%s gen tokens)" % (
    (m.get("content") or "").strip()[:40], len(m.get("reasoning_content") or ""),
    t.get("prompt_per_second", 0), t.get("predicted_per_second", 0), t.get("predicted_n", "?")))'
