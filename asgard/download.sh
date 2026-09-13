#!/bin/sh
# /data/local-ai/asgard/download.sh MODEL - fetch one GGUF (or all shards of a sharded one) into ../models/ (gitignored, on
# the zroot/data/local-ai dataset) with resume + size + sha256 verification against asgard/models.sh (MODEL_FILE/BYTES/SHA256
# = shard 1; MODEL_EXTRA = 'name:bytes:sha256 ...' for the rest; MODEL_DIR = repo sub-folder). Shards are flattened into
# ../models/ - llama-server opens shard 1 and finds -0000N-of-0000M siblings next to it.
# One model at a time (the box has ~10-18 MB/s on 5 GHz Wi-Fi -> ~15 min per 11 GiB file, ~1.5 h per 90 GB).
# Background use: daemon -f -o ~/local-ai-runs/dl-MODEL.log /data/local-ai/asgard/download.sh MODEL  (/var/tmp is a tmpfs wiped at boot)
d=$(dirname "$(realpath "$0")")
. "$d/models.sh"; model_env "${1:-qwen35b}" || exit 1
mkdir -p "$d/../models"; cd "$d/../models" || exit 1
verify() { # file bytes sha256
  size=$(stat -f %z "$1"); sum=$(sha256 -q "$1")
  [ "$size" = "$2" ] && [ "$sum" = "$3" ] && return 0
  echo "VERIFY_FAIL $1: size=$size (want $2) sha256=$sum (want $3)"; return 1
}
fetch() { # file bytes sha256
  URL="https://huggingface.co/$MODEL_REPO/resolve/$MODEL_REV/${MODEL_DIR:+$MODEL_DIR/}$1"
  if [ -f "$1" ]; then verify "$1" "$2" "$3" && { echo "already present and verified: $1"; return 0; }; return 1; fi
  date; echo "fetching $URL"
  /usr/local/bin/curl --fail --location --retry 5 --retry-delay 5 --continue-at - \
    --output "$1.part" "$URL" 2>&1 | tr '\r' '\n' | awk 'NR%40==0'
  date
  verify "$1.part" "$2" "$3" || return 1
  mv "$1.part" "$1" && echo "VERIFIED_OK $1"
}
rc=0
fetch "$MODEL_FILE" "$MODEL_BYTES" "$MODEL_SHA256" || rc=1
for spec in $MODEL_EXTRA; do
  f=${spec%%:*}; rest=${spec#*:}; b=${rest%%:*}; h=${rest#*:}
  fetch "$f" "$b" "$h" || rc=1
done
[ $rc = 0 ] && echo "MODEL_COMPLETE $MODEL_NAME" || echo "MODEL_INCOMPLETE $MODEL_NAME (re-run to resume)"
exit $rc
