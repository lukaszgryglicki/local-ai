#!/bin/sh
# /data/local-ai/asgard/models.sh - per-model settings for the asgard variant (Dell Precision 7750:
# Xeon W-10885M 8C/16T, Quadro RTX 5000 16 GiB via Vulkan, FreeBSD 15.1). Sourced, not run:
#   d=...; . "$d/models.sh"; model_env north
# Names = T-1 tier of asgard/plan.md §4 (whole model + 256K q8_0 KV inside the 16 GiB Quadro).
# Files live in ../models/ (gitignored) on the zroot/data/local-ai dataset (compression=off,
# primarycache=metadata, recordsize=128K - see readme "ZFS: why the model has its own dataset").
# Rules baked in (plan §6): --spec-type draft-mtp ONLY for *-MTP-GGUF files (server aborts at start
# otherwise) -> everything else ngram-mod; --cache-ram 0 where a single per-layer K or V copy of a
# 256K slot exceeds the FreeBSD-nvidia 256 MiB pinned-allocation cap (1088 B/token models).
model_env() {
  MODEL_NAME=$1
  case "$1" in
    north)   # T-1: Cohere North-Mini-Code-1.0, 30B-A3B coder, interleaved thinking (always on), 256K native
      MODEL_FILE=North-Mini-Code-1.0-UD-IQ3_XXS.gguf MODEL_ALIAS=north-mini-code MODEL_TITLE='North-Mini-Code-1.0 UD-IQ3_XXS'
      MODEL_REPO=unsloth/North-Mini-Code-1.0-GGUF MODEL_REV=e306bb4bf0df610f5471d97a01de2b6e0b24d356
      MODEL_BYTES=11708375136 MODEL_SHA256=029b51f93570c4295680bf6fb138bbc51bba7c377d613f75ac4eaa6913597140
      MODEL_SPEC=ngram-mod MODEL_CACHE_RAM=8192 MODEL_NCMOE=0 MODEL_KWARGS=
      MODEL_TEMP=1.0 MODEL_TOP_P=0.95 MODEL_TOP_K=0 MODEL_MIN_P=0.0 ;;      # model card: temp 1.0, top_p 0.95 only
    qwen9b)  # T-1 safe: Qwen3.5-9B dense (hybrid Gated-DeltaNet), MTP head inside the GGUF, thinking via enable_thinking
      MODEL_FILE=Qwen3.5-9B-Q8_0.gguf MODEL_ALIAS=qwen3.5-9b MODEL_TITLE='Qwen3.5-9B Q8_0 (MTP)'
      MODEL_REPO=unsloth/Qwen3.5-9B-MTP-GGUF MODEL_REV=9716a636ee4bddc3fed678220b7a33dd2a4160ae
      MODEL_BYTES=9786061152 MODEL_SHA256=107125cda29dc42d62f5ba8ffac8817d21a9d7bd06c1b35860491a00a170ad4e
      MODEL_SPEC=draft-mtp,ngram-mod MODEL_CACHE_RAM=0 MODEL_NCMOE=0 MODEL_KWARGS='{"enable_thinking":true}'
      MODEL_TEMP=1.0 MODEL_TOP_P=0.95 MODEL_TOP_K=20 MODEL_MIN_P=0.0 ;;     # Qwen3.5 thinking-mode card values
    gemma)   # T-1 alt: Gemma-4-26B-A4B-it (LCB 77 / SWE-V 57), thinking via enable_thinking, no MTP head
      MODEL_FILE=gemma-4-26B-A4B-it-UD-IQ3_S.gguf MODEL_ALIAS=gemma4-26b-a4b MODEL_TITLE='Gemma-4-26B-A4B-it UD-IQ3_S'
      MODEL_REPO=unsloth/gemma-4-26B-A4B-it-GGUF MODEL_REV=c099eb48e663fd284577b04978a94ffccb261841
      MODEL_BYTES=11289671136 MODEL_SHA256=878be93f9c238ea853b3fd1eb602637ce3cf1cddea56dc345d9a7bf2d6093e29
      MODEL_SPEC=ngram-mod MODEL_CACHE_RAM=0 MODEL_NCMOE=0 MODEL_KWARGS='{"enable_thinking":true}'
      MODEL_TEMP=1.0 MODEL_TOP_P=0.95 MODEL_TOP_K=64 MODEL_MIN_P=0.0 ;;     # Gemma card: temp 1.0, top_k 64, top_p 0.95
    qwen35b) # T-1b (test-only): Qwen3.6-35B-A3B UD-IQ2_M, non-MTP file -> ngram-mod
      MODEL_FILE=Qwen3.6-35B-A3B-UD-IQ2_M.gguf MODEL_ALIAS=qwen3.6-35b-a3b MODEL_TITLE='Qwen3.6-35B-A3B UD-IQ2_M'
      MODEL_REPO=unsloth/Qwen3.6-35B-A3B-GGUF MODEL_REV=a483e9e6cbd595906af30beda3187c2663a1118c
      MODEL_BYTES=11522702304 MODEL_SHA256=2be7ef1ed7e1af8b10d3829102cf9a6c2bd5ddb64d675b4ece23a60799403d43
      MODEL_SPEC=ngram-mod MODEL_CACHE_RAM=8192 MODEL_NCMOE=0 MODEL_KWARGS='{"enable_thinking":true}'
      MODEL_TEMP=1.0 MODEL_TOP_P=0.95 MODEL_TOP_K=20 MODEL_MIN_P=0.0 ;;
    *) echo "unknown model '$1' (north|qwen9b|gemma|qwen35b)" >&2; return 1 ;;
  esac
}
