#!/bin/sh
# /data/local-ai/asgard/verify-rust.sh [DIR] - independent verification of the revstr project a model produced
# via e2e-test.sh MODEL rust (DIR defaults to .). Accepts the project either in DIR/revstr/ or directly in DIR (models read
# "in the current directory" both ways). Nothing the model claims is trusted: fresh `cargo build --release`,
# `cargo test`, byte-exact stdin round-trips against Python's s[::-1] (with and without trailing newline),
# signature/test-count/deps/unsafe checks on the source, then a one-line VERDICT.
W=${1:-.}; cd "$W" || exit 1
if [ -f revstr/Cargo.toml ]; then P=revstr; elif [ -f Cargo.toml ]; then P=.; else
  echo "FILES MISSING: neither revstr/Cargo.toml nor ./Cargo.toml"; ls -laR . 2>/dev/null | grep -v "^total" | head -30
  echo "VERDICT: FAIL (no project)"; exit 1
fi
main=$P/src/main.rs
[ -f "$main" ] || { echo "FILES MISSING: $main"; echo "VERDICT: FAIL (no src/main.rs)"; exit 1; }
name=$(awk -F'"' '/^\[package\]/{f=1;next} /^\[/{f=0} f && /^name *=/{print $2; exit}' $P/Cargo.toml)
others=$(ls $P/src | grep -v '^main.rs$' | tr '\n' ' ')
echo "project: $P/ (package '$name', $(wc -l < $main | tr -d ' ') lines in src/main.rs${others:+, other src files: $others})"
deps=$(awk '/^\[dependencies\]/{f=1;next} /^\[/{f=0} f && NF && $0 !~ /^#/' $P/Cargo.toml)
if [ -z "$deps" ]; then echo "deps: none (ok)"; depsok=1; else echo "deps: FOUND external deps: $deps"; depsok=0; fi
grep -Eq 'pub fn reverse\s*\(\s*s\s*:\s*&str\s*\)\s*->\s*String' "$main" && { echo "signature: pub fn reverse(s: &str) -> String ok"; sigok=1; } || { echo "signature: MISSING/different: $(grep -E 'fn reverse' "$main" | head -1)"; sigok=0; }
echo "tests in source: $(grep -c '#\[test\]' "$main") | unsafe blocks: $(grep -c 'unsafe' "$main") | uses chars().rev(): $(grep -Eq 'chars\(\)\s*\.rev\(\)' "$main" && echo yes || echo no)"
rm -rf $P/target
if ( cd $P && cargo build --release -q 2>build.err ); then echo "build: ok"; buildok=1; else echo "build: FAIL"; head -20 $P/build.err; buildok=0; fi
tres=$( cd $P && cargo test -q 2>&1 | grep -E "test result|^error" | head -3 ); echo "cargo test: $(echo "$tres" | tr '\n' ' ')"
echo "$tres" | grep -q "test result: ok" && ! echo "$tres" | grep -q "FAILED" && testok=1 || testok=0
bin=$P/target/release/$name
rtok=0
if [ -x "$bin" ]; then
  python3 - "$bin" <<'EOF' && rtok=1
import subprocess, sys
b = sys.argv[1]
cases = ["hello", "Zażółć gęślą jaźń", "a🚀b👍", "", "racecar", "  spaced out  ", "e\u0301x\u0308", "ab\ncd", "abc\n"]
ok = bad = 0
for s in cases:
    for tail in ("\n", ""):  # with and without the single trailing newline the spec says to strip
        inp = (s + tail).encode(); want = (s[::-1] + "\n").encode()
        try:
            r = subprocess.run([b], input=inp, capture_output=True, timeout=10); got = r.stdout
        except Exception as e:  # noqa: BLE001
            got = ("EXC " + str(e)).encode()
        if got == want and r.returncode == 0: ok += 1
        else:
            bad += 1; print("round-trip FAIL: stdin=%r rc=%s got=%r want=%r" % (inp, r.returncode, got, want))
print("round-trips: %d ok, %d failed (%d inputs x with/without trailing newline)" % (ok, bad, len(cases)))
sys.exit(1 if bad else 0)
EOF
else
  echo "round-trips: binary $bin not found"
fi
if [ "$buildok" = 1 ] && [ "$testok" = 1 ] && [ "$rtok" = 1 ] && [ "$sigok" = 1 ] && [ "$depsok" = 1 ]; then
  echo "VERDICT: PASS"
else
  echo "VERDICT: FAIL (build=$buildok test=$testok roundtrips=$rtok signature=$sigok nodeps=$depsok)"
fi
echo "-- $main:"; cat "$main"
