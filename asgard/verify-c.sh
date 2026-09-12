#!/bin/sh
# /data/local-ai/asgard/verify-c.sh [DIR] - independent verification of the bignum C project a model produced
# (project in DIR/bignum/ or DIR itself). Strict compile (-std=c11 -Wall -Wextra -Werror -O2), make + make test,
# --selftest, an ASan/UBSan build, then byte-exact comparison against Python integers on fixed edge cases plus
# 400 random lines (signed, up to 3 000 digits) fed through the sanitizer build, malformed-line handling and exit
# status. Ends with a VERDICT line.
W=${1:-.}; cd "$W" || exit 1
if [ -f bignum/bignum.c ]; then P=bignum; elif [ -f bignum.c ]; then P=.; else
  echo "FILES MISSING: no bignum.c in ./bignum or ."; ls -laR . 2>/dev/null | grep -v "^total" | head -30; echo "VERDICT: FAIL (no project)"; exit 1
fi
cd "$P" || exit 1
srcs=bignum.c   # the spec's build command names bignum.c only; other *.c files are the model's scratch, reported but not built
others=$(ls *.c *.h 2>/dev/null | grep -v '^bignum\.c$' | tr '\n' ' ')
echo "project: $P/ (bignum.c $(wc -l < bignum.c | tr -d ' ') lines${others:+; other files left behind: $others}; Makefile: $( [ -f Makefile ] && echo yes || echo MISSING); targets: $(grep -oE '^(all|test|clean):' Makefile 2>/dev/null | tr -d ':' | tr '\n' ' '))"
echo "malloc/free calls in bignum.c: $(grep -cE '\b(malloc|calloc|realloc)\(' bignum.c) / $(grep -c '\bfree(' bignum.c) | assert() uses: $(grep -c 'assert(' bignum.c) | fixed buffers >= 1000: $(grep -cE '\[[0-9]{4,}\]' bignum.c)"
rm -f bignum bignum-asan *.o
cc -std=c11 -Wall -Wextra -Werror -O2 -o bignum $srcs 2>strict.err && { echo "strict build (-Werror): ok"; strictok=1; } || { echo "strict build (-Werror): FAIL"; head -15 strict.err; strictok=0; }
cc -std=c11 -g -O1 -fsanitize=address,undefined -fno-omit-frame-pointer -o bignum-asan $srcs 2>asan-build.err && { echo "sanitizer build: ok"; asanb=1; } || { echo "sanitizer build: FAIL"; head -10 asan-build.err; asanb=0; }
if [ -f Makefile ]; then
  make clean >/dev/null 2>&1; make >make.out 2>&1 && [ -x bignum ] && { echo "make: ok"; makeok=1; } || { echo "make: FAIL"; tail -10 make.out; makeok=0; }
  mt=$(make test 2>&1 | tail -3 | tr '\n' ' '); echo "make test: $(echo "$mt" | cut -c1-200)"
  echo "$mt" | grep -q "selftest ok" && makete=1 || makete=0
else makeok=0; makete=0; fi
[ -x bignum-asan ] && { st=$(./bignum-asan --selftest 2>&1 | tail -2 | tr '\n' ' '); echo "selftest under ASan/UBSan: $(echo "$st" | cut -c1-160)"; echo "$st" | grep -q "selftest ok" && ! echo "$st" | grep -qi "sanitizer\|runtime error" && selfok=1 || selfok=0; } || selfok=0
cmpok=0
if [ -x bignum-asan ]; then
  python3 - ./bignum-asan <<'EOF' && cmpok=1
import random, subprocess, sys
sys.set_int_max_str_digits(100000)
b = sys.argv[1]; rng = random.Random(20260911)
def num(maxd):
    d = rng.randint(1, maxd); v = rng.randrange(10 ** (d - 1), 10 ** d) if d > 1 else rng.randrange(0, 10)
    return -v if rng.random() < 0.4 else v
lines = [(0, "+", 0), (0, "-", 0), (0, "*", 5), (-7, "*", 0), (5, "-", 5), (-5, "-", -5), (1, "-", 2), (-1, "+", 1), (999, "+", 1), (1000, "-", 1),
         (-999, "-", 1), (123456789, "*", 987654321), (-12, "*", 12), (10 ** 30, "-", 10 ** 30 - 1), (10 ** 1000 + 7, "*", 10 ** 1000 - 7), (-(10 ** 500), "+", 10 ** 500),
         (10 ** 2999, "*", -(10 ** 2999)), (99999999999999999999, "+", 1), (-(10 ** 40), "-", -(10 ** 40)), (3, "*", -4)]
for _ in range(400):
    lines.append((num(3000 if rng.random() < 0.1 else 60), rng.choice("+-*"), num(3000 if rng.random() < 0.1 else 60)))
inp = "".join("%d %s %d\n" % l for l in lines)
want = "".join("%d\n" % (a + c if op == "+" else a - c if op == "-" else a * c) for a, op, c in lines)
r = subprocess.run([b], input=inp.encode(), capture_output=True, timeout=300)
got = r.stdout.decode("utf-8", "replace")
if got == want and r.returncode == 0 and b"Sanitizer" not in r.stderr and b"runtime error" not in r.stderr:
    print("arithmetic: %d lines ok (20 edge cases + 400 random, up to 3 000 digits), exit 0, sanitizers quiet" % len(lines)); ok = True
else:
    ok = False; g = got.split("\n"); w = want.split("\n"); bad = [i for i in range(len(w)) if i >= len(g) or g[i] != w[i]]
    print("arithmetic: FAIL rc=%s, %d/%d lines wrong; first: line %s: %r\n  got  %s\n  want %s" % (r.returncode, len(bad), len(lines), bad[:1], lines[bad[0]] if bad else None, (g[bad[0]][:80] if bad and bad[0] < len(g) else "<missing>"), (w[bad[0]][:80] if bad else "")))
    if r.stderr: print("  stderr:", r.stderr.decode("utf-8", "replace")[:300])
# malformed lines + blank lines + continue processing + exit 0
inp = "1 + 1\n\nfoo\n2 ** 3\n12 / 4\n 3 + 3\n1 + \n-0 + 0\n007 + 1\n5 - -5\n".encode()
r = subprocess.run([b], input=inp, capture_output=True, timeout=30)
lines_out = r.stdout.decode("utf-8", "replace").split("\n")
exp_first = ["2", "error", "error", "error"]
if lines_out[:4] == exp_first and lines_out[-2] == "10" and r.returncode == 0 and b"Sanitizer" not in r.stderr:
    print("malformed/blank lines: ok (%r)" % lines_out[:-1])
else:
    ok = False; print("malformed/blank lines: FAIL rc=%s got %r stderr=%r" % (r.returncode, lines_out, r.stderr[:200]))
# empty input
r = subprocess.run([b], input=b"", capture_output=True, timeout=30)
if r.stdout == b"" and r.returncode == 0: print("empty input: ok")
else: ok = False; print("empty input: FAIL rc=%s out=%r" % (r.returncode, r.stdout[:80]))
sys.exit(0 if ok else 1)
EOF
else
  echo "comparisons: no sanitizer binary"
fi
if [ "$strictok" = 1 ] && [ "$makeok" = 1 ] && [ "$makete" = 1 ] && [ "$selfok" = 1 ] && [ "$cmpok" = 1 ]; then echo "VERDICT: PASS"
else echo "VERDICT: FAIL (strict=$strictok make=$makeok maketest=$makete selftest_asan=$selfok comparisons=$cmpok)"; fi
for f in bignum.c Makefile; do [ -f "$f" ] && { echo "-- $P/$f:"; cat "$f"; }; done
