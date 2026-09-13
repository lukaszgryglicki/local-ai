#!/bin/sh
# /data/local-ai/asgard/models.sh - per-model settings for the asgard variant (Dell Precision 7750:
# Xeon W-10885M 8C/16T, Quadro RTX 5000 16 GiB via Vulkan, FreeBSD 15.1). Sourced, not run:
#   d=...; . "$d/models.sh"; model_env qwen35b
# Names = plan.md §4 tiers: T-1 (whole model + 256K q8_0 KV inside the 16 GiB Quadro) and T0 (experts that do not fit
# VRAM go to CPU RAM, MODEL_NCMOE=N; the iGPU = Vulkan1 path (MODEL_IGPU_MOE=N) measured 2x slower and is retired, results-t0.md §1).
# T-1 is FROZEN (13 Sep 2026): qwen35b is the `fastest-vram` profile and the default model of start.sh / serve.sh / qwen.sh /
# llamactl.sh (results-t1.md §5, report-t1.md §8). The other T-1 candidates (north 0/4, qwen9b 1/4, gemma 1/4) were removed
# on 13 Sep 00:30 - GGUFs deleted, entries dropped from this file; their settings live in git history and report-t1.md.
# Files live in ../models/ (gitignored) on the zroot/data/local-ai dataset (compression=off,
# primarycache=metadata, recordsize=128K - see readme "ZFS: why the model has its own dataset"; `all` from 11 Sep was reverted
# 13 Sep 01:05 and vfs.zfs.arc.max=16 GiB went into /etc/sysctl.conf: an unlimited ARC starves the NVIDIA pinned host
# buffers that --n-cpu-moe needs - results-t0.md §3.2).
# Rules baked in (plan §6): --spec-type draft-mtp ONLY for *-MTP-GGUF files (server aborts at start
# otherwise) -> everything else ngram-mod, except where a sweep showed a loss (qwen35b: none, +17 %);
# --cache-ram 0 where a single per-layer K or V copy of a 256K slot is >= 256 MiB (1088 B/token models) -
# the NVIDIA driver's pinned-allocation windows; harmless since the chunked-staging build (build-vulkan-2).
model_env() {
  MODEL_NAME=$1
  case "$1" in
    qwen35b) # T-1 WINNER = `fastest-vram` (frozen 13 Sep): Qwen3.6-35B-A3B UD-IQ2_M, non-MTP file; SPEC=none (ngram-mod costs 17 % here)
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
      MODEL_TEMP=1.0 MODEL_TOP_P=0.95 MODEL_TOP_K=20 MODEL_MIN_P=0.0 ;;     # NCMOE=20 = fit ladder 12 Sep (15 144 MiB; k=18 UP but 500 on 1st decode)
    kat-q4)  # T0b: KAT-Coder-V2.5-Dev = Qwen3.6-35B-A3B fine-tuned for agentic coding (Kwaipilot), Q4_K_L, no MTP head
      MODEL_FILE=Kwaipilot_KAT-Coder-V2.5-Dev-Q4_K_L.gguf MODEL_ALIAS=kat-coder-v2.5 MODEL_TITLE='KAT-Coder-V2.5-Dev Q4_K_L'
      MODEL_REPO=bartowski/Kwaipilot_KAT-Coder-V2.5-Dev-GGUF MODEL_REV=d8f684f08d2950ea9d2db6a35ef7dada0707858b
      MODEL_BYTES=21768894880 MODEL_SHA256=bb0441b81a7cac064ae2fc139e6d4d0ef53dbdc8916ba117605070b7c03e455e
      MODEL_SPEC=none MODEL_CACHE_RAM=8192 MODEL_NCMOE=19 MODEL_IGPU_MOE=0 MODEL_KWARGS='{"enable_thinking":true}'
      MODEL_TEMP=1.0 MODEL_TOP_P=0.95 MODEL_TOP_K=20 MODEL_MIN_P=0.0 ;;     # KAT card thinking mode: temp 1.0, top_p 0.95, top_k 20; NCMOE=19 = fit ladder 13 Sep (15 267 MiB after 1st request)
    qwen35b-q8) # T0/T1 quality reference: Qwen3.6-35B-A3B Q8_0 (34.4 GiB), ~29 of 40 expert layers outside VRAM
      MODEL_FILE=Qwen3.6-35B-A3B-Q8_0.gguf MODEL_ALIAS=qwen3.6-35b-a3b-q8 MODEL_TITLE='Qwen3.6-35B-A3B Q8_0'
      MODEL_REPO=unsloth/Qwen3.6-35B-A3B-GGUF MODEL_REV=a483e9e6cbd595906af30beda3187c2663a1118c
      MODEL_BYTES=36903140320 MODEL_SHA256=d1a395809f65a43a13ad119eb4e7acdef1ac6d68120f39902c8ab96e72794a59
      MODEL_SPEC=none MODEL_CACHE_RAM=8192 MODEL_NCMOE=29 MODEL_IGPU_MOE=0 MODEL_KWARGS='{"enable_thinking":true}'
      MODEL_TEMP=1.0 MODEL_TOP_P=0.95 MODEL_TOP_K=20 MODEL_MIN_P=0.0 ;;     # NCMOE=29 fit-confirmed 13 Sep 01:04: k=27 fails, k=29 = 15 011 -> 15 064 MiB after a 4K request (results-t0.md §5.1)
    *) echo "unknown model '$1' (T-1 winner: qwen35b  T0 candidates: qwen35b-q4|kat-q4|qwen35b-q8)" >&2; return 1 ;;
  esac
}
