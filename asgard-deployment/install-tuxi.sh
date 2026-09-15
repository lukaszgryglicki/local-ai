#!/bin/sh
# /data/local-ai/asgard-deployment/install-tuxi.sh - the remote clients on tuxi (no llama runs on tuxi):  ./install-tuxi.sh
#   /data/scripts/qwen.sh qwen-t0.sh qwen-t1.sh qwen-t2.sh  <- copies of the files next to this script (re-run after a git pull)
# They reach asgard's server through an ssh tunnel (opened on demand) and read the API key from /data/local-ai/key.secret,
# which is the same file on both hosts.
set -eu
D=$(dirname "$(realpath "$0")")
rc=0
chk() { if eval "$1"; then echo "ok    $2"; else echo "MISSING $2"; rc=1; fi; }
chk '[ -r /data/local-ai/key.secret ]' "API key /data/local-ai/key.secret (copy it from asgard with mode 600 if missing)"
chk 'command -v qwen >/dev/null' "qwen CLI (Qwen Code): npm install -g @qwen-code/qwen-code"
chk 'ssh -o BatchMode=yes -o ConnectTimeout=5 asgard true 2>/dev/null' "passwordless ssh to asgard (host entry + key)"
mkdir -p /data/scripts
for f in qwen.sh qwen-t0.sh qwen-t1.sh qwen-t2.sh; do
  install -m 755 "$D/$f" "/data/scripts/$f" && echo "installed /data/scripts/$f"
done
[ $rc = 0 ] && echo "install complete" || echo "install complete with MISSING items above"
exit $rc
