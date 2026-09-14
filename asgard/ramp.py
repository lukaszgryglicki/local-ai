#!/usr/bin/env python3
# /data/local-ai/asgard/ramp.py - gap-free geometric load ramp on the RUNNING server, run right before the first real request.
# Why (results-t1.md §6.2, drops #1-#6): every spontaneous AC-adapter dropout of the campaign sits on the *first* large
# partial-offload prefill after a load - the GPU jumps from idle to full boost while PCIe streams the expert weights from
# RAM; the EC declares the adapter "Off Line" and pins the Quadro at 1035 MHz / P2 until a cold power-off. A pinned GPU never
# drops. Drop #6 (14 Sep 11:53:16) hit llama-server's built-in warm-up (a decode with ALL experts active - the largest
# possible step, before start.sh's ramp could run) -> serve.sh now passes --no-warmup and the ramp is the first GPU work.
# The ramp sends 1 -> 4 -> 16 -> ... -> RAMP_MAX prompt tokens (4 generated tokens each, cache_prompt off) back-to-back, so
# the GPU boost/power controller is already engaged and the platform current rises in <= 4x steps instead of one cliff.
# Callers: start.sh (after UP), bench.py/codebench.py (after settle(), i.e. immediately before the measured request),
# e2e-test.sh (RAMP_MAX=16384, before qwen-code's ~23K system prompt). Env: RAMP_MAX (4096), NO_RAMP=1 skips, RAMP_QUIET=1.
# Standalone: python3 ramp.py [max_tokens]  -> one summary line on stderr, exit 0 (also when the server is not up: ramp is
# best-effort and must never fail a caller).
import json, os, sys, time, urllib.request

BASE = "http://10.253.254.1:18080"
_KEY = None
def _key():
    global _KEY
    if _KEY is None:
        try:
            _KEY = open(os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "key.secret")).read().strip()
        except OSError:
            _KEY = ""
    return _KEY

def _post(path, obj, timeout=1800):
    req = urllib.request.Request(BASE + path, json.dumps(obj).encode(),
                                 {"Content-Type": "application/json", "Authorization": "Bearer " + _key()})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode())

def _gpu():
    try:
        import subprocess
        return subprocess.run(["nvidia-smi", "--query-gpu=clocks.sm,power.draw,pstate", "--format=csv,noheader"],
                              capture_output=True, text=True, timeout=5).stdout.strip()
    except Exception:
        return "?"

def ramp(max_tokens=None, quiet=None):
    """Return the number of completed steps (0 when skipped or the server is down)."""
    if os.environ.get("NO_RAMP", "0") == "1":
        return 0
    max_tokens = int(max_tokens or os.environ.get("RAMP_MAX", "4096"))
    quiet = os.environ.get("RAMP_QUIET", "0") == "1" if quiet is None else quiet
    steps, n = [], 1
    while n < max_tokens:
        steps.append(n); n *= 4
    steps.append(max_tokens)
    t0 = time.time(); done = 0; last = ""
    try:
        with urllib.request.urlopen(BASE + "/health", timeout=5) as r:
            if b"ok" not in r.read():
                raise OSError("not ok")
    except Exception as e:
        if not quiet:
            sys.stderr.write("ramp: server not up (%s) - skipped\n" % e)
        return 0
    for w in steps:
        try:
            _post("/completion", {"prompt": "word " * w, "n_predict": 4, "cache_prompt": False, "temperature": 0})
            done += 1
        except Exception as e:
            last = " (step %d failed: %s)" % (w, str(e)[:60]); break
    if not quiet:
        sys.stderr.write("ramp: %d/%d steps (1..%d tokens, back-to-back) in %.0f s%s | GPU %s\n"
                         % (done, len(steps), max_tokens, time.time() - t0, last, _gpu()))
        sys.stderr.flush()
    return done

if __name__ == "__main__":
    ramp(int(sys.argv[1]) if len(sys.argv) > 1 else None)
    sys.exit(0)
