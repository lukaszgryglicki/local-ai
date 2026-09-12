#!/bin/sh
# /data/local-ai/asgard/models.sh - per-model settings for the asgard variant (Dell Precision 7750:
# Xeon W-10885M 8C/16T, Quadro RTX 5000 16 GiB via Vulkan, FreeBSD 15.1). Sourced, not run:
#   d=...; . "$d/models.sh"; model_env qwen35b
# Names = plan.md §4 tiers: T-1 (whole model + 256K q8_0 KV inside the 16 GiB Quadro) and T0 (experts that do not fit
# VRAM go to the iGPU = Vulkan1 (MODEL_IGPU_MOE=N) or to CPU RAM (MODEL_NCMOE=N), whichever the sweep measures faster).
# T-1 WINNER (12 Sep 2026, results-t1.md §5): qwen35b - 2/4 E2E tasks + a near-miss, 30-46 t/s, SPEC=none, NP=1;
# it is the default model of start.sh / serve.sh / qwen.sh / llamactl.sh. north 0/4, qwen9b 1/4, gemma 1/4.
# Files live in ../models/ (gitignored) on the zroot/data/local-ai dataset (compression=off,
# primarycache=metadata, recordsize=128K - see readme "ZFS: why the model has its own dataset").
# Rules baked in (plan §6): --spec-type draft-mtp ONLY for *-MTP-GGUF files (server aborts at start
# otherwise) -> everything else ngram-mod, except where a sweep showed a loss (qwen35b: none, +17 %);
# --cache-ram 0 where a single per-layer K or V copy of a 256K slot is >= 256 MiB (1088 B/token models) -
# the NVIDIA driver's pinned-allocation windows; harmless since the chunked-staging build (build-vulkan-2).
model_env() {
  MODEL_NAME=$1
  case "$1" in
    north)   # T-1: Cohere North-Mini-Code-1.0, 30B-A3B coder, interleaved thinking (always on), 256K native
      MODEL_FILE=North-Mini-Code-1.0-UD-IQ3_XXS.gguf MODEL_ALIAS=north-mini-code MODEL_TITLE='North-Mini-Code-1.0 UD-IQ3_XXS'
      MODEL_REPO=unsloth/North-Mini-Code-1.0-GGUF MODEL_REV=e306bb4bf0df610f5471d97a01de2b6e0b24d356
      MODEL_BYTES=11708375136 MODEL_SHA256=029b51f93570c4295680bf6fb138bbc51bba7c377d613f75ac4eaa6913597140
      MODEL_SPEC=ngram-mod MODEL_CACHE_RAM=8192 MODEL_NCMOE=0 MODEL_IGPU_MOE=0 MODEL_KWARGS=
      MODEL_TEMP=1.0 MODEL_TOP_P=0.95 MODEL_TOP_K=0 MODEL_MIN_P=0.0 ;;      # model card: temp 1.0, top_p 0.95 only
    qwen9b)  # T-1 safe: Qwen3.5-9B dense (hybrid Gated-DeltaNet), MTP head inside the GGUF, thinking via enable_thinking
      MODEL_FILE=Qwen3.5-9B-Q8_0.gguf MODEL_ALIAS=qwen3.5-9b MODEL_TITLE='Qwen3.5-9B Q8_0 (MTP)'
      MODEL_REPO=unsloth/Qwen3.5-9B-MTP-GGUF MODEL_REV=9716a636ee4bddc3fed678220b7a33dd2a4160ae
      MODEL_BYTES=9786061152 MODEL_SHA256=107125cda29dc42d62f5ba8ffac8817d21a9d7bd06c1b35860491a00a170ad4e
      MODEL_SPEC=draft-mtp,ngram-mod MODEL_CACHE_RAM=0 MODEL_NCMOE=0 MODEL_IGPU_MOE=0 MODEL_KWARGS='{"enable_thinking":true}'
      MODEL_TEMP=1.0 MODEL_TOP_P=0.95 MODEL_TOP_K=20 MODEL_MIN_P=0.0 ;;     # Qwen3.5 thinking-mode card values
    gemma)   # T-1 alt: Gemma-4-26B-A4B-it (LCB 77 / SWE-V 57), thinking via enable_thinking, no MTP head
      MODEL_FILE=gemma-4-26B-A4B-it-UD-IQ3_S.gguf MODEL_ALIAS=gemma4-26b-a4b MODEL_TITLE='Gemma-4-26B-A4B-it UD-IQ3_S'
      MODEL_REPO=unsloth/gemma-4-26B-A4B-it-GGUF MODEL_REV=c099eb48e663fd284577b04978a94ffccb261841
      MODEL_BYTES=11289671136 MODEL_SHA256=878be93f9c238ea853b3fd1eb602637ce3cf1cddea56dc345d9a7bf2d6093e29
      MODEL_SPEC=ngram-mod MODEL_CACHE_RAM=0 MODEL_NCMOE=0 MODEL_IGPU_MOE=0 MODEL_KWARGS='{"enable_thinking":true}'
      MODEL_TEMP=1.0 MODEL_TOP_P=0.95 MODEL_TOP_K=64 MODEL_MIN_P=0.0 ;;     # Gemma card: temp 1.0, top_k 64, top_p 0.95
    qwen35b) # T-1 WINNER: Qwen3.6-35B-A3B UD-IQ2_M, non-MTP file; SPEC=none (sweep: ngram-mod costs 17 % on this MoE)
      MODEL_FILE=Qwen3.6-35B-A3B-UD-IQ2_M.gguf MODEL_ALIAS=qwen3.6-35b-a3b MODEL_TITLE='Qwen3.6-35B-A3B UD-IQ2_M'
      MODEL_REPO=unsloth/Qwen3.6-35B-A3B-GGUF MODEL_REV=a483e9e6cbd595906af30beda3187c2663a1118c
      MODEL_BYTES=11522702304 MODEL_SHA256=2be7ef1ed7e1af8b10d3829102cf9a6c2bd5ddb64d675b4ece23a60799403d43
      MODEL_SPEC=none MODEL_CACHE_RAM=8192 MODEL_NCMOE=0 MODEL_IGPU_MOE=0 MODEL_KWARGS='{"enable_thinking":true}'
      MODEL_TEMP=1.0 MODEL_TOP_P=0.95 MODEL_TOP_K=20 MODEL_MIN_P=0.0 ;;
    qwen35b-q4) # T0: same model as the T-1 winner at 4-bit (UD-Q4_K_XL); experts overflow VRAM -> iGPU or RAM (plan §10)
      MODEL_FILE=Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf MODEL_ALIAS=qwen3.6-35b-a3b-q4 MODEL_TITLE='Qwen3.6-35B-A3B UD-Q4_K_XL'
      MODEL_REPO=unsloth/Qwen3.6-35B-A3B-GGUF MODEL_REV=a483e9e6cbd595906af30beda3187c2663a1118c
      MODEL_BYTES=22360456160 MODEL_SHA256=707a55a8a4397ecde44de0c499d3e68c1ad1d240d1da65826b4949d1043f4450
      MODEL_SPEC=none MODEL_CACHE_RAM=8192 MODEL_NCMOE=20 MODEL_IGPU_MOE=0 MODEL_KWARGS='{"enable_thinking":true}'
      MODEL_TEMP=1.0 MODEL_TOP_P=0.95 MODEL_TOP_K=20 MODEL_MIN_P=0.0 ;;     # NCMOE/IGPU_MOE = plan estimate until the fit ladder
    kat-q4)  # T0b: KAT-Coder-V2.5-Dev = Qwen3.6-35B-A3B fine-tuned for agentic coding (Kwaipilot), Q4_K_L, no MTP head
      MODEL_FILE=Kwaipilot_KAT-Coder-V2.5-Dev-Q4_K_L.gguf MODEL_ALIAS=kat-coder-v2.5 MODEL_TITLE='KAT-Coder-V2.5-Dev Q4_K_L'
      MODEL_REPO=bartowski/Kwaipilot_KAT-Coder-V2.5-Dev-GGUF MODEL_REV=d8f684f08d2950ea9d2db6a35ef7dada0707858b
      MODEL_BYTES=21768894880 MODEL_SHA256=bb0441b81a7cac064ae2fc139e6d4d0ef53dbdc8916ba117605070b7c03e455e
      MODEL_SPEC=none MODEL_CACHE_RAM=8192 MODEL_NCMOE=20 MODEL_IGPU_MOE=0 MODEL_KWARGS='{"enable_thinking":true}'
      MODEL_TEMP=1.0 MODEL_TOP_P=0.95 MODEL_TOP_K=20 MODEL_MIN_P=0.0 ;;     # KAT card thinking mode: temp 1.0, top_p 0.95, top_k 20
    qwen35b-q8) # T0/T1 quality reference: Qwen3.6-35B-A3B Q8_0 (34.4 GiB), ~29 of 40 expert layers outside VRAM
      MODEL_FILE=Qwen3.6-35B-A3B-Q8_0.gguf MODEL_ALIAS=qwen3.6-35b-a3b-q8 MODEL_TITLE='Qwen3.6-35B-A3B Q8_0'
      MODEL_REPO=unsloth/Qwen3.6-35B-A3B-GGUF MODEL_REV=a483e9e6cbd595906af30beda3187c2663a1118c
      MODEL_BYTES=36903140320 MODEL_SHA256=d1a395809f65a43a13ad119eb4e7acdef1ac6d68120f39902c8ab96e72794a59
      MODEL_SPEC=none MODEL_CACHE_RAM=8192 MODEL_NCMOE=29 MODEL_IGPU_MOE=0 MODEL_KWARGS='{"enable_thinking":true}'
      MODEL_TEMP=1.0 MODEL_TOP_P=0.95 MODEL_TOP_K=20 MODEL_MIN_P=0.0 ;;
    *) echo "unknown model '$1' (T-1: north|qwen9b|gemma|qwen35b  T0: qwen35b-q4|kat-q4|qwen35b-q8)" >&2; return 1 ;;
  esac
}
