#!/usr/bin/env python3
# /data/local-ai/asgard/settle.py - "never measure under a cap": wait until the thermal watchdog has the CPU at the full cap
# (/var/run/thermal-policy.ratio == 53) and the PCH is at most PCH_MAX C, both of which a 20-35 GB model load knocks over
# (the NVMe stream heats the PCH past the watchdog's 90 C turbo band: kat-q4 cpu19-t16b 13 Sep 11:47 ran at cap 2400-3200,
# qwen35b-q8 igpu29 12:08 started at cap 2400). Imported by bench.py and codebench.py; NO_SETTLE=1 skips it, SETTLE_MAX_S
# (default 180) bounds the wait, SETTLE_PCH_MAX (default 86) the temperature. Prints one line to stderr when it had to wait.
import os, subprocess, sys, time

def _pch():
    try:
        return float(subprocess.run(["sysctl", "-n", "dev.pchtherm.0.temperature"], capture_output=True, text=True).stdout.strip().rstrip("C"))
    except Exception:
        return None

def _ratio():
    try:
        return open("/var/run/thermal-policy.ratio").read().strip()
    except Exception:
        return None

def settle(max_s=None, pch_max=None):
    if os.environ.get("NO_SETTLE"):
        return 0
    max_s = int(os.environ.get("SETTLE_MAX_S", max_s or 180)); pch_max = float(os.environ.get("SETTLE_PCH_MAX", pch_max or 86))
    t0 = time.time(); waited = 0
    while time.time() - t0 < max_s:
        r, t = _ratio(), _pch()
        if (r is None or r == "53") and (t is None or t <= pch_max):
            break
        if waited == 0:
            sys.stderr.write("settle: cap ratio %s, pch %s C - waiting for ratio 53 and pch <= %.0f C (max %d s)\n" % (r, t, pch_max, max_s)); sys.stderr.flush()
        time.sleep(5); waited = int(time.time() - t0)
    if waited:
        sys.stderr.write("settle: waited %d s -> ratio %s, pch %s C\n" % (waited, _ratio(), _pch())); sys.stderr.flush()
    return waited

if __name__ == "__main__":
    sys.exit(0 if settle() >= 0 else 1)
