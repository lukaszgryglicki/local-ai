#!/usr/bin/env python3
"""verify-slow.py [options] FILE [EXPECTED_SHA256] - duty-cycled sha256 of FILE that keeps the PCH cool.
Prints the hex digest on stdout (progress/pauses on stderr); with EXPECTED_SHA256 given exits 0/1 on match/mismatch.

  --burst S    hash at full speed for S seconds ...            (default 40, env VERIFY_BURST)
  --cool S     ... then stop reading for S seconds             (default 15, env VERIFY_COOL)
  --pch-hi C   safety net: pause when the PCH reaches C ...    (default 88, env VERIFY_PCH_HI; was 100 until 13 Sep 12:05: a
               40/15 duty cycle at full clocks hit 100 C four times in 4 min and tripped the watchdog cap; the PCH's own hw link
                                                                throttle starts at 108 C, the watchdog suspends at 115)
  --pch-lo C   ... until it is back at C                        (default 78, env VERIFY_PCH_LO; keeps the run under the
               watchdog's 90 C turbo-band limit, so a verification never costs CPU clocks elsewhere)
  --mbps N     optional read-rate cap in MB/s, 0 = none        (default 0, env VERIFY_MBPS)

asgard 2026-09-13: the PCH (CometLake-H, all four NVMe links + DMI hang off it, passively cooled) jumps ~8-10 C within
seconds of ANY sustained NVMe read stream and then creeps up ~6 C/min - a 98 MB/s `sha256 -q` went 65 -> 107 C, a
40 MB/s rate-limited read 79 -> 97 C, with every core at 36 C - and it drops back just as fast once the reads stop.
So the read *rate* is not the lever, the duty cycle is: bursts of --burst s, gaps of --cool s. The first closed-loop
version (pause at 84 C, resume at 74 C) gave ~20 s bursts / 20-35 s gaps and PCH 73-85 C; the owner asked for fixed
40/15 s to try next (2026-09-13 10:35). Used by download.sh (env vars pass through)."""
import hashlib, os, subprocess, sys, time

CHUNK = 4 << 20


def log(msg):
    sys.stderr.write("verify-slow %s %s\n" % (time.strftime("%H:%M:%S"), msg))
    sys.stderr.flush()


def pch():
    try:
        out = subprocess.run(["sysctl", "-n", os.environ.get("VERIFY_PCH_OID", "dev.pchtherm.0.temperature")],
                             capture_output=True, text=True, timeout=5).stdout
        return float(out.strip().rstrip("C"))
    except Exception:
        return None


def parse(argv):
    opts = {"burst": float(os.environ.get("VERIFY_BURST", "40")), "cool": float(os.environ.get("VERIFY_COOL", "15")),
            "pch-hi": float(os.environ.get("VERIFY_PCH_HI", "88")), "pch-lo": float(os.environ.get("VERIFY_PCH_LO", "78")),
            "mbps": float(os.environ.get("VERIFY_MBPS", "0"))}
    args = []
    it = iter(argv)
    for a in it:
        if a in ("-h", "--help"):
            sys.exit(__doc__)
        if a.startswith("--") and a[2:] in opts:
            try:
                opts[a[2:]] = float(next(it))
            except (StopIteration, ValueError):
                sys.exit("verify-slow: %s needs a number" % a)
        elif a.startswith("-") and len(a) > 1:
            sys.exit("verify-slow: unknown option %s\n%s" % (a, __doc__))
        else:
            args.append(a)
    if not args:
        sys.exit(__doc__)
    return opts, args[0], (args[1].lower() if len(args) > 1 else None)


def main():
    o, path, want = parse(sys.argv[1:])
    total = os.path.getsize(path)
    h = hashlib.sha256()
    done = 0
    t0 = time.monotonic()
    burst_start = t0
    last_check = last_prog = 0.0
    paused = 0.0
    gaps = safety = 0
    pmax = 0.0
    log("start %s: %.1f GiB, burst/cool %.0f/%.0f s, pch safety hi/lo %.0f/%.0f C, rate cap %s, pch now %s C"
        % (os.path.basename(path), total / 2**30, o["burst"], o["cool"], o["pch-hi"], o["pch-lo"],
           "%.0f MB/s" % o["mbps"] if o["mbps"] > 0 else "none", pch()))
    with open(path, "rb", buffering=0) as f:
        while True:
            b = f.read(CHUNK)
            if not b:
                break
            h.update(b)
            done += len(b)
            now = time.monotonic()
            if o["cool"] > 0 and now - burst_start >= o["burst"]:      # fixed duty cycle
                gaps += 1
                t = pch()
                if t is not None:
                    pmax = max(pmax, t)
                time.sleep(o["cool"])
                paused += o["cool"]
                t2 = pch()
                if gaps % 10 == 1:
                    log("gap #%d after %.0f s burst: pch %s -> %s C (%.1f/%.1f GiB done)" % (gaps, o["burst"], t, t2, done / 2**30, total / 2**30))
                burst_start = time.monotonic()
                last_check = burst_start
                now = burst_start
            if now - last_check >= 1.0:                                  # safety net on the PCH
                last_check = now
                t = pch()
                if t is not None:
                    pmax = max(pmax, t)
                    if t >= o["pch-hi"]:
                        safety += 1
                        p0 = time.monotonic()
                        log("SAFETY pause #%d at pch %.0f C >= %.0f C (%.1f/%.1f GiB done)" % (safety, t, o["pch-hi"], done / 2**30, total / 2**30))
                        while True:
                            time.sleep(5)
                            t = pch()
                            if t is None or t <= o["pch-lo"]:
                                break
                        paused += time.monotonic() - p0
                        log("resume at pch %s C after %.0f s" % ("?" if t is None else "%.0f" % t, time.monotonic() - p0))
                        burst_start = last_check = time.monotonic()
            if o["mbps"] > 0:
                ahead = done / (o["mbps"] * 2**20) - (now - t0 - paused)
                if ahead > 0:
                    time.sleep(ahead)
            if now - last_prog >= 300:
                last_prog = now
                log("%.1f/%.1f GiB, pch %s C (max %.0f), paused %.0f s so far (%d gaps, %d safety pauses)"
                    % (done / 2**30, total / 2**30, pch(), pmax, paused, gaps, safety))
    el = time.monotonic() - t0
    log("done %.1f GiB in %.0f s (hashing %.0f s at %.0f MB/s, paused %.0f s: %d gaps, %d safety pauses), pch max %.0f C, now %s C"
        % (total / 2**30, el, el - paused, total / 2**20 / max(el - paused, 1e-9), paused, gaps, safety, pmax, pch()))
    digest = h.hexdigest()
    print(digest)
    if want is not None:
        sys.exit(0 if digest == want else 1)


main()
