#!/bin/sh
# /data/local-ai/asgard/verify-asm.sh [DIR] - independent verification of the b64 x86-64 assembly project a model
# produced (project in DIR/b64/ or DIR itself). Assembles with GNU as + ld exactly as the task says, checks the binary
# is static and libc-free, regenerates the acceptance vectors (never trusts the VECTORS.txt the model could edit) and
# runs all of them in both directions, random blobs of awkward sizes (0..1 000 003 bytes), a delayed pipe (short
# reads), decoder error cases and exit statuses, then make/make test. Ends with a VERDICT line.
W=${1:-.}; cd "$W" || exit 1
d=$(dirname "$(realpath "$0")")
if [ -f b64/b64.s ]; then P=b64; elif [ -f b64.s ]; then P=.; else
  echo "FILES MISSING: no b64.s in ./b64 or ."; ls -laR . 2>/dev/null | grep -v "^total" | head -30; echo "VERDICT: FAIL (no project)"; exit 1
fi
cd "$P" || exit 1
echo "project: $P/ (b64.s $(wc -l < b64.s | tr -d ' ') lines, $(grep -cE '^\s*[a-zA-Z_.][a-zA-Z0-9_.]*:' b64.s) labels, syscall instructions: $(grep -c 'syscall' b64.s); Makefile: $( [ -f Makefile ] && echo yes || echo MISSING); test.sh: $( [ -f test.sh ] && echo yes || echo MISSING))"
rm -f b64.o b64-verify
as b64.s -o b64.o 2>as.err && ld -o b64-verify b64.o 2>ld.err && { echo "as + ld: ok"; buildok=1; } || { echo "as + ld: FAIL"; head -10 as.err ld.err 2>/dev/null; buildok=0; }
if [ -x b64-verify ]; then
  echo "binary: $(file -b b64-verify | cut -c1-90); undefined symbols: $(nm -u b64-verify 2>/dev/null | wc -l | tr -d ' '); size $(stat -f %z b64-verify) bytes"
  nolibc=1; ldd b64-verify 2>/dev/null | grep -q "=>" && nolibc=0; [ "$(nm -u b64-verify 2>/dev/null | wc -l | tr -d ' ')" = 0 ] || nolibc=0
else nolibc=0; fi
cmpok=0
if [ -x b64-verify ]; then
  python3 "$d/e2e-vectors.py" 700 .vectors-verify.txt
  python3 - ./b64-verify .vectors-verify.txt <<'EOF' && cmpok=1
import base64, random, subprocess, sys, time
sys.set_int_max_str_digits(100000)
b = sys.argv[1]; rng = random.Random(7)
def run(args, inp, timeout=30):
    r = subprocess.run([b] + args, input=inp, capture_output=True, timeout=timeout); return r.returncode, r.stdout, r.stderr
ok = bad = 0
def check(name, cond, detail=""):
    global ok, bad
    if cond: ok += 1
    else:
        bad += 1
        if bad <= 6: print("FAIL %s %s" % (name, detail))
# 1. acceptance vectors, both directions
ve = vd = 0
for line in open(sys.argv[2]):
    hx, b64 = line.rstrip("\n").split("\t"); raw = bytes.fromhex(hx)
    rc, out, _ = run([], raw); ve += (rc == 0 and out == b64.encode())
    rc, out, _ = run(["-d"], b64.encode()); vd += (rc == 0 and out == raw)
check("vectors encode", ve == 700, "%d/700" % ve); check("vectors decode", vd == 700, "%d/700" % vd)
print("vectors: encode %d/700, decode %d/700" % (ve, vd))
# 2. random blobs of awkward sizes (buffer boundaries)
sizes = [0, 1, 2, 3, 4, 5, 6, 57, 58, 100, 4095, 4096, 4097, 8191, 8192, 8193, 65535, 65536, 65537, 1000003]
be = bd = 0
for n in sizes:
    raw = rng.randbytes(n); enc = base64.b64encode(raw)
    rc, out, err = run([], raw, 120); good = rc == 0 and out == enc; be += good
    if not good and bad < 6: print("FAIL encode %d bytes: rc=%s len(out)=%d (want %d) stderr=%r" % (n, rc, len(out), len(enc), err[:80]))
    rc, out, err = run(["-d"], enc, 120); good = rc == 0 and out == raw; bd += good
    if not good and bad < 6: print("FAIL decode %d bytes: rc=%s len(out)=%d (want %d) stderr=%r" % (n, rc, len(out), n, err[:80]))
check("blobs encode", be == len(sizes), "%d/%d" % (be, len(sizes))); check("blobs decode", bd == len(sizes), "%d/%d" % (bd, len(sizes)))
print("random blobs (%d sizes up to 1 000 003 B): encode %d, decode %d ok" % (len(sizes), be, bd))
# 3. short reads: pipe with delays between chunks
p = subprocess.Popen([b], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
for chunk in (b"ab", b"c", b"defg", b"h"):
    p.stdin.write(chunk); p.stdin.flush(); time.sleep(0.3)
p.stdin.close(); p.stdin = None; out, err = p.communicate(timeout=30)
check("short reads encode", p.returncode == 0 and out == base64.b64encode(b"abcdefgh"), "rc=%s out=%r" % (p.returncode, out[:40]))
p = subprocess.Popen([b, "-d"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
for chunk in (b"YW", b"JjZG", b"VmZ2\n", b"g="):
    p.stdin.write(chunk); p.stdin.flush(); time.sleep(0.3)
p.stdin.close(); p.stdin = None; out, err = p.communicate(timeout=30)
check("short reads decode", p.returncode == 0 and out == b"abcdefgh", "rc=%s out=%r" % (p.returncode, out[:40]))
# 4. decoder: newlines ignored (incl. 76-col wrapped, CRLF is NOT allowed -> only \n is a newline per spec)
raw = rng.randbytes(300); wrapped = base64.encodebytes(raw)  # 76-col lines with \n
rc, out, _ = run(["-d"], wrapped); check("decode wrapped", rc == 0 and out == raw, "rc=%s" % rc)
rc, out, _ = run(["-d"], b"\n\nYWJj\n\n"); check("decode leading/trailing newlines", rc == 0 and out == b"abc", "rc=%s out=%r" % (rc, out))
# 5. decoder errors -> exit 1
for name, inp in (("bad char", b"YW*j"), ("length not multiple of 4", b"YWJ"), ("bad padding", b"YW=j"), ("too much padding", b"Y==="), ("space", b"YW Jj")):
    rc, out, _ = run(["-d"], inp); check("decode error: " + name, rc == 1, "rc=%s out=%r" % (rc, out[:20]))
# 6. usage: unknown argument -> exit 2, message on stderr
rc, out, err = run(["-x"], b""); check("usage exit 2", rc == 2 and out == b"" and err.strip() != b"", "rc=%s out=%r err=%r" % (rc, out[:20], err[:40]))
# 7. no trailing newline, nothing on stderr on success
rc, out, err = run([], b"hi"); check("no trailing newline / quiet stderr", out == b"aGk=" and err == b"", "out=%r err=%r" % (out, err[:40]))
print("checks: %d ok, %d failed" % (ok, bad))
sys.exit(1 if bad else 0)
EOF
  rm -f .vectors-verify.txt
else
  echo "checks: binary not built"
fi
if [ -f Makefile ]; then
  make clean >/dev/null 2>&1; make >make.out 2>&1 && [ -x b64 ] && { echo "make: ok"; makeok=1; } || { echo "make: FAIL"; tail -8 make.out; makeok=0; }
  mt=$(make test 2>&1 | tail -3 | tr '\n' ' '); echo "make test: $(echo "$mt" | cut -c1-200)"
else makeok=0; fi
# graded score (13 Sep): functional = as+ld, checks, make; spec = nolibc
fn=$(( ${buildok:-0} + ${cmpok:-0} + ${makeok:-0} )); sp=$(( ${nolibc:-0} )); sc="score=$((fn+sp))/4 functional=$fn/3 spec=$sp/1"
if [ "$buildok" = 1 ] && [ "$nolibc" = 1 ] && [ "$cmpok" = 1 ] && [ "$makeok" = 1 ]; then echo "VERDICT: PASS $sc"
else echo "VERDICT: FAIL (as+ld=$buildok nolibc=$nolibc checks=$cmpok make=$makeok) $sc"; fi
echo "-- $P/b64.s:"; cat b64.s
for f in Makefile test.sh; do [ -f "$f" ] && { echo "-- $P/$f:"; cat "$f"; }; done
