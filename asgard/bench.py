#!/usr/bin/env python3
# /data/local-ai/asgard/bench.py LABEL [depths...] - pp/tg vs context depth on the RUNNING asgard server.
# Derived from remote/bench-ab.py (same idea: exact-token prefixes sharing a common prefix, so
# successive depths only prefill the delta through the prompt cache) but uses the raw /completion
# endpoint with token prompts: /v1/chat/completions + ignore_eos makes strict chat parsers (North's
# peg-native format) return HTTP 500 once the model is forced past its end token.
# Default depths go to ~252K so the last row doubles as the 256K survival check (OOM / DeviceLost).
# Env: GEN=tokens to generate per row (128). Prints CSV: label,depth_req,prompt_n,pp_tps,gen_n,tg_tps,wall_s
import json, os, sys, time, urllib.request

BASE = "http://10.253.254.1:18080"
KEY = open(os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "key.secret")).read().strip()
LABEL = sys.argv[1] if len(sys.argv) > 1 else "cfg"
from settle import settle; settle()   # never measure under the watchdog cap / hot PCH (asgard/settle.py, NO_SETTLE=1 skips)
DEPTHS = [int(x) for x in sys.argv[2:]] or [256, 2048, 16384, 32768, 65536, 131072, 258048]
GEN = int(os.environ.get("GEN", "128"))

def post(path, obj, timeout=7200):
    req = urllib.request.Request(
        BASE + path, json.dumps(obj).encode(),
        {"Authorization": "Bearer " + KEY, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())

# deterministic filler corpus, tokenized once, cut at exact token counts
need = max(DEPTHS) + 4096
sent = ["Benchmark sentence number %d keeps the tokenizer busy with plain "
        "prose about clusters, kernels, compilers and databases." % i
        for i in range(need // 16)]
text = " ".join(sent)
toks = post("/tokenize", {"content": text})["tokens"]
while len(toks) <= max(DEPTHS):
    sent += ["Extra filler sentence %d about schedulers, allocators and caches." % i
             for i in range(len(sent), len(sent) + need // 32)]
    text = " ".join(sent)
    toks = post("/tokenize", {"content": text})["tokens"]
sys.stderr.write("filler tokenized: %d tokens\n" % len(toks))

suffix = post("/tokenize", {"content": "\n\nWrite a short poem about benchmarks.\n"})["tokens"]

# warmup: first inference after a fresh load would contaminate the first row
post("/completion", {"prompt": toks[:64], "n_predict": 32, "temperature": 0.0, "ignore_eos": True})
sys.stderr.write("warmup done\n")

for depth in DEPTHS:
    body = {"prompt": toks[: max(depth - len(suffix), 1)] + suffix, "n_predict": GEN,
            "temperature": 0.0, "ignore_eos": True, "cache_prompt": True}
    t0 = time.time()
    try:
        resp = post("/completion", body)
    except Exception as e:  # noqa: BLE001 - report the failure row and continue
        print("%s,%d,ERROR,%s" % (LABEL, depth, str(e).replace(",", ";")[:120]), flush=True)
        continue
    wall = time.time() - t0
    tm = resp.get("timings") or {}
    print("%s,%d,%s,%.2f,%s,%.2f,%.1f" % (
        LABEL, depth,
        tm.get("prompt_n", "?"), tm.get("prompt_per_second", 0.0),
        tm.get("predicted_n", "?"), tm.get("predicted_per_second", 0.0),
        wall), flush=True)
