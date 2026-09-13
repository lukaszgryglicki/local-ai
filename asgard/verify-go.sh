#!/bin/sh
# /data/local-ai/asgard/verify-go.sh [DIR] - independent verification of the wordfreq Go project a model produced
# (project in DIR/wordfreq/ or DIR itself). go vet, go build, go test, then byte-exact comparison of the binary's
# output against a Python reference implementation of the spec on 11 inputs x several -n values, the -n<1 exit
# status, and a 6 MB input (performance sanity). Ends with a VERDICT line.
W=${1:-.}; cd "$W" || exit 1
if [ -f wordfreq/go.mod ]; then P=wordfreq; elif [ -f go.mod ]; then P=.; else
  echo "FILES MISSING: no go.mod in ./wordfreq or ."; ls -laR . 2>/dev/null | grep -v "^total" | head -30; echo "VERDICT: FAIL (no project)"; exit 1
fi
cd "$P" || exit 1
gofiles=$(ls *.go 2>/dev/null | tr '\n' ' '); tests=$(ls *_test.go 2>/dev/null | wc -l | tr -d ' ')
echo "project: $P/ (module $(awk '/^module/{print $2; exit}' go.mod); files: $gofiles; $(cat *.go | wc -l | tr -d ' ') lines; test files: $tests, test funcs: $(grep -h '^func Test' *_test.go 2>/dev/null | wc -l | tr -d ' '))"
req=$(awk '/^require/{f=1} f && /\)/{f=0} f && !/^require/ && NF && $0 !~ /\/\/ indirect/' go.mod | wc -l | tr -d ' ')
[ "$req" = 0 ] && { echo "deps: none (ok)"; depsok=1; } || { echo "deps: FOUND external modules in go.mod: $req"; depsok=0; }
rm -rf ./wordfreq-bin
go vet ./... 2>vet.err && { echo "go vet: ok"; vetok=1; } || { echo "go vet: FAIL"; head -10 vet.err; vetok=0; }
go build -o wordfreq-bin . 2>build.err && { echo "build: ok"; buildok=1; } || { echo "build: FAIL"; head -20 build.err; buildok=0; }
tres=$(go test ./... 2>&1 | tail -3 | tr '\n' ' '); echo "go test: $tres"
echo "$tres" | grep -q "^ok" && ! echo "$tres" | grep -q "FAIL" && testok=1 || testok=0
rtok=0
if [ -x ./wordfreq-bin ]; then
  python3 - ./wordfreq-bin <<'EOF' && rtok=1
import subprocess, sys, re
b = sys.argv[1]
def ref(text, n):
    words = [w.lower() for w in re.findall(r"[^\W_]+", text)]
    cnt = {}
    for w in words: cnt[w] = cnt.get(w, 0) + 1
    return "".join("%d\t%s\n" % (c, w) for w, c in sorted(cnt.items(), key=lambda kv: (-kv[1], kv[0]))[:n])
cases = [
    "", "the The THE tHe a a b", "Zażółć gęślą jaźń, zażółć! ZAŻÓŁĆ gęślą.",
    "42 42 x42 42x 7 7 7\n0042", "foo_bar foo bar foo-bar foo.bar", "a b c d e f g h i j k l m",
    "line one\nline two\r\nline three\ttabbed\n\n\nline", "Über straße STRASSE Straße", "don't stop-believing; it's 'quoted' “fancy” — dash…",
    "Ala ma kota, kot ma Alę. ALA! kota? Kota.", "x " * 1000 + "y " * 999 + "z",
]
ok = bad = 0
for text in cases:
    for n in (10, 1, 3, 100):
        want = ref(text, n)
        try:
            r = subprocess.run([b, "-n", str(n)], input=text.encode(), capture_output=True, timeout=20)
            got = r.stdout.decode("utf-8", "replace")
        except Exception as e:  # noqa: BLE001
            r = None; got = "EXC " + str(e)
        if r is not None and got == want and r.returncode == 0: ok += 1
        else:
            bad += 1
            if bad <= 4: print("FAIL: -n %d input=%r\n  got=%r\n want=%r rc=%s stderr=%r" % (n, text[:60], got[:200], want[:200], r.returncode if r else None, (r.stderr[:120] if r else b"")))
# default -n is 10
text = cases[5]; r = subprocess.run([b], input=text.encode(), capture_output=True, timeout=20)
if r.stdout.decode() == ref(text, 10) and r.returncode == 0: ok += 1
else: bad += 1; print("FAIL: default -n should be 10: got %d lines" % r.stdout.decode().count("\n"))
# -n 0 -> exit 2, nothing on stdout
r = subprocess.run([b, "-n", "0"], input=b"a b", capture_output=True, timeout=20)
if r.returncode == 2 and r.stdout == b"": ok += 1
else: bad += 1; print("FAIL: -n 0 should exit 2 with empty stdout: rc=%s stdout=%r stderr=%r" % (r.returncode, r.stdout[:80], r.stderr[:120]))
# performance sanity: 6 MB
big = ("Zażółć gęślą jaźń lorem ipsum dolor sit amet 12345 foo_bar " * 100000)
r = subprocess.run([b, "-n", "5"], input=big.encode(), capture_output=True, timeout=60)
if r.stdout.decode() == ref(big, 5) and r.returncode == 0: ok += 1; print("6 MB input: ok")
else: bad += 1; print("FAIL: 6 MB input rc=%s got=%r" % (r.returncode, r.stdout[:120]))
print("comparisons: %d ok, %d failed" % (ok, bad))
sys.exit(1 if bad else 0)
EOF
else
  echo "comparisons: binary not built"
fi
# graded score (13 Sep): functional = build, test, comparisons; spec = vet, nodeps
fn=$(( ${buildok:-0} + ${testok:-0} + ${rtok:-0} )); sp=$(( ${vetok:-0} + ${depsok:-0} )); sc="score=$((fn+sp))/5 functional=$fn/3 spec=$sp/2"
if [ "$buildok" = 1 ] && [ "$vetok" = 1 ] && [ "$testok" = 1 ] && [ "$rtok" = 1 ] && [ "$depsok" = 1 ]; then echo "VERDICT: PASS $sc"
else echo "VERDICT: FAIL (build=$buildok vet=$vetok test=$testok comparisons=$rtok nodeps=$depsok) $sc"; fi
for f in $gofiles; do echo "-- $P/$f:"; cat "$f"; done
