#!/bin/sh
# /data/local-ai/asgard-deployment/install.sh - install the frozen asgard llama tiers on asgard (idempotent):  sudo ./install.sh
#   /usr/local/etc/rc.d/llama-t0 llama-t1 llama-t2   <- rc.d/ (mode 555; KEYWORD nostart: never started at boot)
#   /data/scripts/qwen.sh qwen-t0.sh qwen-t1.sh qwen-t2.sh  -> symlinks into this directory (one source of truth = git)
# Then: sudo service llama-t0 start | stop | status | restart   and   qwen-t0.sh / qwen.sh   (see README.md).
set -eu
D=$(dirname "$(realpath "$0")")
[ "$(id -u)" = 0 ] || { echo "run as root: sudo $0" >&2; exit 1; }
[ "$(hostname -s)" = asgard ] || { echo "this installer is for asgard (use install-tuxi.sh on tuxi)" >&2; exit 1; }
rc=0
chk() { if eval "$1"; then echo "ok    $2"; else echo "MISSING $2"; rc=1; fi; }
chk '[ -x /data/ai/local-agent-poc/src/llama.cpp/build-vulkan-2/bin/llama-server ]' "llama-server build-vulkan-2 (T0/T1)"
chk '[ -x /data/ai/local-agent-poc/src/llama.cpp-master/build-vulkan-master/bin/llama-server ]' "llama-server build-vulkan-master (T2)"
chk '[ -f /data/local-ai/models/Qwen3.6-35B-A3B-UD-IQ2_M.gguf ]' "T0 model file"
chk '[ -f /data/local-ai/models/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf ]' "T1 model file"
chk '[ -f /data/local-ai/models/Qwen3.8-Flash-Next-UD-IQ4_XS-00003-of-00003.gguf ]' "T2 model files (3 shards)"
chk '[ -f /data/local-ai/key.secret ]' "API key /data/local-ai/key.secret"
chk 'command -v qwen >/dev/null' "qwen CLI (Qwen Code) for the client scripts"
chk 'command -v nvidia-smi >/dev/null' "nvidia-smi"
for t in t0 t1 t2; do
  install -o root -g wheel -m 555 "$D/rc.d/llama-$t" "/usr/local/etc/rc.d/llama-$t" && echo "installed /usr/local/etc/rc.d/llama-$t"
done
chmod 755 "$D/llama-tier.sh" "$D/qwen.sh" "$D"/qwen-t?.sh
mkdir -p /data/scripts
for f in qwen.sh qwen-t0.sh qwen-t1.sh qwen-t2.sh; do
  ln -sfh "$D/$f" "/data/scripts/$f" && echo "linked /data/scripts/$f -> $D/$f"
done
grep -q 'llama_t[012]_enable' /etc/rc.conf 2>/dev/null && echo "note: /etc/rc.conf has llama_tN_enable lines (not needed; the stubs default to YES and nostart keeps them out of the boot)"
echo "boot check: $(rcorder -s nostart /usr/local/etc/rc.d/llama-t0 /usr/local/etc/rc.d/llama-t1 /usr/local/etc/rc.d/llama-t2 2>/dev/null | wc -l | tr -d ' ') of 3 tier scripts would run at boot (must be 0)"
[ $rc = 0 ] && echo "install complete" || echo "install complete with MISSING items above"
exit $rc
