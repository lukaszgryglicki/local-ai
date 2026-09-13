#!/usr/bin/env python3
# /data/local-ai/asgard/codebench.py LABEL [n_prompts] - realistic decode benchmark on the RUNNING server:
# short coding prompts through /v1/chat/completions (thinking on, model's own EOS, no ignore_eos), so
# speculative decoding is measured on real code/reasoning output instead of filler text.
# Env: MAXTOK (4096) per answer; TEMP/TOP_P/TOP_K/MIN_P override the sampling sent (default: let the
# server defaults apply = the model's own settings from asgard/models.sh).
# Prints CSV per prompt: label,idx,prompt_n,pp_tps,gen_n,tg_tps,wall_s,reasoning_chars,content_chars
# and a final line: label,TOTAL,gen_tokens,gen_seconds,tg_tps_aggregate
import json, os, sys, time, urllib.request

BASE = "http://10.253.254.1:18080"
KEY = open(os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "key.secret")).read().strip()
LABEL = sys.argv[1] if len(sys.argv) > 1 else "cfg"
from settle import settle; settle()   # never measure under the watchdog cap / hot PCH (asgard/settle.py, NO_SETTLE=1 skips)
N = int(sys.argv[2]) if len(sys.argv) > 2 else 3
MAXTOK = int(os.environ.get("MAXTOK", "4096"))
PROMPTS = [
    "Write a Rust function `reverse(s: &str) -> String` that reverses a string by chars (Unicode scalar values), plus three unit tests. Keep the explanation to two sentences.",
    "Write a Python function that parses an nginx access log line into a dict (ip, time, method, path, status, bytes) using one compiled regex, with a short docstring and one doctest.",
    "In Go, implement a bounded worker pool: `func Run(jobs []func() error, workers int) []error` that runs the jobs on at most `workers` goroutines and returns the errors in job order. Include a table-driven test.",
    "Write a POSIX sh script that rotates files matching /var/log/app-*.log older than 7 days into /var/log/archive/YYYY-MM/ as gzip, skipping files still open (use fstat or lsof if available). Comment each step.",
]

def post(path, obj, timeout=7200):
    req = urllib.request.Request(BASE + path, json.dumps(obj).encode(),
                                 {"Authorization": "Bearer " + KEY, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())

sampling = {}
for k, env in (("temperature", "TEMP"), ("top_p", "TOP_P"), ("top_k", "TOP_K"), ("min_p", "MIN_P")):
    if os.environ.get(env) is not None:
        sampling[k] = float(os.environ[env]) if k != "top_k" else int(os.environ[env])

tot_n = 0; tot_s = 0.0
for i, p in enumerate(PROMPTS[:N]):
    body = {"model": "bench", "stream": False, "max_tokens": MAXTOK,
            "messages": [{"role": "user", "content": p}]}
    body.update(sampling)
    t0 = time.time()
    try:
        r = post("/v1/chat/completions", body)
    except Exception as e:  # noqa: BLE001
        print("%s,%d,ERROR,%s" % (LABEL, i, str(e).replace(",", ";")[:120]), flush=True); continue
    wall = time.time() - t0
    tm = r.get("timings") or {}; m = r["choices"][0]["message"]
    gn = tm.get("predicted_n", 0) or 0; gms = tm.get("predicted_ms", 0) or 0
    tot_n += gn; tot_s += gms / 1000
    print("%s,%d,%s,%.1f,%d,%.2f,%.1f,%d,%d" % (
        LABEL, i, tm.get("prompt_n", "?"), tm.get("prompt_per_second", 0.0), gn,
        tm.get("predicted_per_second", 0.0), wall, len(m.get("reasoning_content") or ""),
        len(m.get("content") or "")), flush=True)
print("%s,TOTAL,%d,%.1f,%.2f" % (LABEL, tot_n, tot_s, tot_n / tot_s if tot_s else 0), flush=True)
