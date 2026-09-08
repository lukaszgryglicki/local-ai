#!/bin/sh
# /data/local-ai/tokenize.sh - show how the REMOTE model tokenizes the argument.
# Uses the live llama-server /tokenize endpoint through the tunnel
# (tunnel.sh must be running). Works on the host (127.0.0.1:18081) and in the
# bhyve VM (falls back to 10.253.254.1:18081).
#   usage: ./tokenize.sh "any text you want"
d=$(dirname "$(realpath "$0")")
[ $# -ge 1 ] || { echo "usage: $0 \"text to tokenize\""; exit 1; }
u=http://127.0.0.1:18081
curl -s -m 5 "$u/health" >/dev/null 2>&1 || u=http://10.253.254.1:18081
printf '%s' "$*" | python3 -c '
import json, sys, subprocess
text = sys.stdin.read()
url, key = sys.argv[1], sys.argv[2]
body = json.dumps({"content": text, "with_pieces": True})
out = subprocess.run(
    ["curl", "-s", "-m", "30", url + "/tokenize",
     "-H", "Authorization: Bearer " + key,
     "-H", "Content-Type: application/json", "-d", body],
    capture_output=True, text=True)
try:
    toks = json.loads(out.stdout)["tokens"]
except Exception:
    sys.exit("no/bad answer from %s (tunnel.sh up? server serving?): %s"
             % (url, out.stdout[:200]))
print(" | ".join(repr(t["piece"]) for t in toks))
print("%d chars -> %d tokens" % (len(text), len(toks)))
' "$u" "$(cat "$d/remote-key.secret")"
