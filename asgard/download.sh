#!/bin/sh
# /data/local-ai/asgard/download.sh MODEL - fetch one T-1 GGUF into ../models/ (gitignored, on the
# zroot/data/local-ai dataset) with resume + size + sha256 verification against asgard/models.sh.
# One model at a time (the box has ~10-13 MB/s on 5 GHz Wi-Fi -> ~15 min per 11 GiB file).
# Background use: daemon -f -o /var/tmp/local-ai-dl-MODEL.log /data/local-ai/asgard/download.sh MODEL
d=$(dirname "$(realpath "$0")")
. "$d/models.sh"; model_env "${1:-north}" || exit 1
mkdir -p "$d/../models"; cd "$d/../models" || exit 1
URL="https://huggingface.co/$MODEL_REPO/resolve/$MODEL_REV/$MODEL_FILE"
verify() {
  size=$(stat -f %z "$1"); sum=$(sha256 -q "$1")
  [ "$size" = "$MODEL_BYTES" ] && [ "$sum" = "$MODEL_SHA256" ] && return 0
  echo "VERIFY_FAIL $1: size=$size (want $MODEL_BYTES) sha256=$sum (want $MODEL_SHA256)"; return 1
}
if [ -f "$MODEL_FILE" ]; then verify "$MODEL_FILE" && echo "already present and verified: $MODEL_FILE"; exit $?; fi
date; echo "fetching $URL"
/usr/local/bin/curl --fail --location --retry 5 --retry-delay 5 --continue-at - \
  --output "$MODEL_FILE.part" "$URL" 2>&1 | tr '\r' '\n' | awk 'NR%40==0'
date
verify "$MODEL_FILE.part" || exit 1
mv "$MODEL_FILE.part" "$MODEL_FILE" && echo "VERIFIED_OK $MODEL_FILE"
