#!/usr/bin/env python3
# /data/ai/bench-ab.py - measure pp/tg vs context depth on the RUNNING server.
# Run ON the main node: python3 /data/ai/bench-ab.py LABEL [depths...]
# Uses exact-token prefixes (via /tokenize + /detokenize) that share a common
# prefix, so successive depths only prefill the delta (server prompt cache).
# Prints CSV: label,depth_req,prompt_n,pp_tps,gen_n,tg_tps,wall_s
import json, sys, time, urllib.request

BASE = "http://127.0.0.1:18080"
KEY = open("/data/ai/key.secret").read().strip()
LABEL = sys.argv[1] if len(sys.argv) > 1 else "cfg"
DEPTHS = [int(x) for x in sys.argv[2:]] or [2048, 16384, 32768, 49152]

def post(path, obj, timeout=7200):
    req = urllib.request.Request(
        BASE + path, json.dumps(obj).encode(),
        {"Authorization": "Bearer " + KEY, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())

# deterministic filler corpus, tokenized once, cut at exact token counts
sent = ["Benchmark sentence number %d keeps the tokenizer busy with plain "
        "prose about clusters, kernels, compilers and databases." % i
        for i in range(9000)]
text = " ".join(sent)
toks = post("/tokenize", {"content": text})["tokens"]
assert len(toks) > max(DEPTHS), "filler too small: %d" % len(toks)
sys.stderr.write("filler tokenized: %d tokens\n" % len(toks))

# warmup: first inference after a fresh load pays expert page-in (mmap) and
# would contaminate the first row (seen 2026-09-09: cold 2K row pp 7.9 vs
# warm 20.5). One short throwaway generation heats the active experts.
post("/v1/chat/completions", {
    "model": "bench", "stream": False, "max_tokens": 32, "temperature": 0.0,
    "ignore_eos": True,
    "messages": [{"role": "user", "content": "Warmup. Count to ten."}]})
sys.stderr.write("warmup done\n")

for depth in DEPTHS:
    prefix = post("/detokenize", {"tokens": toks[: depth - 60]})["content"]
    body = {
        "model": "bench", "stream": False,
        "messages": [{"role": "user", "content":
                      prefix + "\n\nWrite a short poem about benchmarks."}],
        "max_tokens": 128, "temperature": 0.0, "ignore_eos": True,
    }
    t0 = time.time()
    resp = post("/v1/chat/completions", body)
    wall = time.time() - t0
    tm = resp.get("timings") or {}
    print("%s,%d,%s,%.2f,%s,%.2f,%.1f" % (
        LABEL, depth,
        tm.get("prompt_n", "?"), tm.get("prompt_per_second", 0.0),
        tm.get("predicted_n", "?"), tm.get("predicted_per_second", 0.0),
        wall), flush=True)
