#!/bin/sh
# /data/local-ai/asgard/download.sh MODEL - fetch one GGUF (or all shards of a sharded one) into ../models/ (gitignored, on
# the zroot/data/local-ai dataset) with resume + size + sha256 verification against asgard/models.sh (MODEL_FILE/BYTES/SHA256
# = shard 1; MODEL_EXTRA = 'name:bytes:sha256 ...' for the rest; MODEL_DIR = repo sub-folder). Shards are flattened into
# ../models/ - llama-server opens shard 1 and finds -0000N-of-0000M siblings next to it.
# One model at a time (the box has ~10-18 MB/s on 5 GHz Wi-Fi -> ~15 min per 11 GiB file, ~1.5 h per 90 GB).
# Background use: daemon -f -o ~/local-ai-runs/dl-MODEL.log /data/local-ai/asgard/download.sh MODEL  (/var/tmp is a tmpfs wiped at boot)
# Verification (2026-09-13): a passed file gets a marker ../models/.verified/NAME ("bytes sha256 date") and is never re-hashed
# on later runs (REVERIFY=1 forces it) - the old re-hash-on-every-run took 8-10 min per shard and heated the PCH to 101-107 C
# (two sha256 at once after queue restarts). The hash itself runs through verify-slow.py at VERIFY_MBPS (default 40 MB/s,
# ~21 min per 50 GB shard, PCH-safe) under nice; the thermal-watchdog SIGSTOPs it at PCH >= 90 C anyway. No timing runs
# (sweeps/benches/E2E) while a verification runs - the PCH >= 85 C drops the CPU turbo band to 2.4 GHz.
d=$(dirname "$(realpath "$0")")
. "$d/models.sh"; model_env "${1:-qwen35b}" || exit 1
mkdir -p "$d/../models/.verified"; cd "$d/../models" || exit 1
V=.verified
verify() { # file bytes sha256   (file may be NAME.part; the marker is written for NAME)
  name=${1%.part}; size=$(stat -f %z "$1")
  if [ -z "${REVERIFY:-}" ] && [ -f "$V/$name" ] && [ "$size" = "$2" ]; then
    read -r mb ms when < "$V/$name"
    [ "$mb" = "$2" ] && [ "$ms" = "$3" ] && { echo "verified earlier ($when, marker $V/$name): $1"; return 0; }
  fi
  # size first: curl's exit status is hidden by the progress pipeline, so an early-ended .part reaches verify(); hashing a
  # file of the wrong size is a pointless 5-10 min NVMe stream at PCH 100 C (13 Sep 11:59, 41 of 49.7 GB) - fail at once instead
  [ "$size" = "$2" ] || { echo "VERIFY_FAIL $1: size=$size (want $2) - not hashing, re-run resumes the download"; return 1; }
  if [ -x "$d/verify-slow.py" ]; then sum=$(nice -n 20 "$d/verify-slow.py" "$1"); else sum=$(nice -n 20 sha256 -q "$1"); fi
  if [ "$size" = "$2" ] && [ "$sum" = "$3" ]; then echo "$2 $3 $(date '+%FT%T')" > "$V/$name"; return 0; fi
  echo "VERIFY_FAIL $1: size=$size (want $2) sha256=$sum (want $3)"; return 1
}
fetch() { # file bytes sha256
  URL="https://huggingface.co/$MODEL_REPO/resolve/$MODEL_REV/${MODEL_DIR:+$MODEL_DIR/}$1"
  if [ -f "$1" ]; then verify "$1" "$2" "$3" && { echo "already present and verified: $1"; return 0; }; echo "present but FAILED verification, kept: $1"; return 1; fi
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
