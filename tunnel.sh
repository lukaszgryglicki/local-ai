#!/bin/sh
# /data/local-ai/tunnel.sh - run on the FreeBSD host (e.g. in tmux).
# Forwards the remote llama-server (127.0.0.1:18080 there) to:
#   http://127.0.0.1:18081     (this host)
#   http://10.253.254.1:18081  (bhyve VMs via the bridge)
# Remote ssh target: remote-host.secret; API key: remote-key.secret.
# Loops forever: reconnects on drops; Ctrl-C to stop for real.
d=$(dirname "$(realpath "$0")")
trap 'echo "[$(date +%T)] tunnel stopped"; exit 0' INT TERM
while :; do
  echo "[$(date +%T)] tunnel up on 127.0.0.1:18081 + 10.253.254.1:18081 (silence = healthy)"
  ssh -N \
    -o ServerAliveInterval=30 -o ServerAliveCountMax=4 \
    -o ExitOnForwardFailure=yes -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=accept-new \
    -L 127.0.0.1:18081:127.0.0.1:18080 \
    -L 10.253.254.1:18081:127.0.0.1:18080 \
    "$(cat "$d/remote-host.secret")"
  echo "[$(date +%T)] tunnel dropped (or port busy) - retrying in 5s, Ctrl-C to quit"
  sleep 5
done
