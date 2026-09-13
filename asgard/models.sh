#!/bin/sh
# /data/local-ai/asgard/models.sh - per-model settings for the asgard variant (Dell Precision 7750:
# Xeon W-10885M 8C/16T, Quadro RTX 5000 16 GiB via Vulkan, FreeBSD 15.1). Sourced, not run:
#   d=...; . "$d/models.sh"; model_env qwen35b
# Tier numbering since 13 Sep 07:05 (owner): T0 fastest-vram / T1 fast / T2 best / T3 optional (were T-1/T0/T1/T2 in older commits).
# Names = plan.md §4 tiers: T0 (whole model + 256K q8_0 KV inside the 16 GiB Quadro) and T1 (experts that do not fit
# VRAM go to CPU RAM, MODEL_NCMOE=N; the iGPU = Vulkan1 path (MODEL_IGPU_MOE=N) measured 2x slower and is retired, results-t1.md §1).
# T0 is FROZEN (13 Sep 2026): qwen35b is the `fastest-vram` profile and the default model of start.sh / serve.sh / qwen.sh /
# llamactl.sh (results-t0.md §5, report-t0.md §8). The other T0 candidates (north 0/4, qwen9b 1/4, gemma 1/4) were removed
# on 13 Sep 00:30 - GGUFs deleted, entries dropped from this file; their settings live in git history and report-t0.md.
# Files live in ../models/ (gitignored) on the zroot/data/local-ai dataset (compression=off,
# primarycache=metadata, recordsize=128K - see readme "ZFS: why the model has its own dataset"; `all` from 11 Sep was reverted
# 13 Sep 01:05 and vfs.zfs.arc.max=16 GiB went into /etc/sysctl.conf: an unlimited ARC starves the NVIDIA pinned host
# buffers that --n-cpu-moe needs - results-t1.md §3.2).
# Rules baked in (plan §6): --spec-type draft-mtp ONLY for *-MTP-GGUF files (server aborts at start
# otherwise) -> everything else ngram-mod, except where a sweep showed a loss (qwen35b: none, +17 %);
# --cache-ram 0 where a single per-layer K or V copy of a 256K slot is >= 256 MiB (1088 B/token models) -
# the NVIDIA driver's pinned-allocation windows; harmless since the chunked-staging build (build-vulkan-2).
# Tier PROFILES (plan §10) are aliases that resolve to the frozen winner AND pin its winning knobs (NP/CTX/SPEC/NCMOE/
# IGPU_MOE/THREADS - only where the environment does not set them; plain models may set MODEL_THREADS the same way), so `./start.sh vram`, `./llamactl.sh start t0`,
# `MODEL=fastest-vram ./qwen.sh` keep working unchanged when later tiers change the plain defaults of serve.sh/start.sh:
#   vram | t0 | fastest-vram  -> qwen35b, SPEC=none NP=1 CTX=262144 NCMOE=0 IGPU_MOE=0 THREADS=8 THREADS_BATCH=16 (frozen 13 Sep 2026)
#   fast | t1                 -> not frozen yet (T1 in progress, results-t1.md)
#   best | t2                 -> not frozen yet (T2 not started)
model_env() {
  MODEL_PROFILE=
  case "$1" in
    vram|t0|fastest-vram) MODEL_PROFILE=fastest-vram; set -- qwen35b
      NP=${NP:-1} CTX=${CTX:-262144} SPEC=${SPEC:-none} NCMOE=${NCMOE:-0} IGPU_MOE=${IGPU_MOE:-0} THREADS=${THREADS:-8} THREADS_BATCH=${THREADS_BATCH:-16}
      export NP CTX SPEC NCMOE IGPU_MOE THREADS THREADS_BATCH ;;
    fast|t1|best|t2) echo "profile '$1' is not frozen yet (T1 = results-t1.md in progress; T2 not started) - name a model instead" >&2; return 1 ;;
  esac
  MODEL_NAME=$1 MODEL_DIR= MODEL_EXTRA= MODEL_BIN= MODEL_THREADS=   # MODEL_THREADS = per-model --threads default (env THREADS wins; serve.sh falls back to 8); MODEL_BIN = llama-server binary if not build-vulkan-2 (serve.sh); MODEL_DIR = repo sub-folder of sharded files; MODEL_EXTRA = 'shard:bytes:sha256 ...' beyond MODEL_FILE (shard 1, the one llama-server opens)
  case "$1" in
    qwen35b) # T0 WINNER = `fastest-vram` (frozen 13 Sep): Qwen3.6-35B-A3B UD-IQ2_M, non-MTP file; SPEC=none (ngram-mod costs 17 % here)
      MODEL_FILE=Qwen3.6-35B-A3B-UD-IQ2_M.gguf MODEL_ALIAS=qwen3.6-35b-a3b MODEL_TITLE='Qwen3.6-35B-A3B UD-IQ2_M'
      MODEL_REPO=unsloth/Qwen3.6-35B-A3B-GGUF MODEL_REV=a483e9e6cbd595906af30beda3187c2663a1118c
      MODEL_BYTES=11522702304 MODEL_SHA256=2be7ef1ed7e1af8b10d3829102cf9a6c2bd5ddb64d675b4ece23a60799403d43
      MODEL_SPEC=none MODEL_CACHE_RAM=8192 MODEL_NCMOE=0 MODEL_IGPU_MOE=0 MODEL_KWARGS='{"enable_thinking":true}'
      MODEL_TEMP=1.0 MODEL_TOP_P=0.95 MODEL_TOP_K=20 MODEL_MIN_P=0.0 ;;
    qwen35b-q4) # T1: same model as the T0 winner at 4-bit (UD-Q4_K_XL); experts overflow VRAM -> iGPU or RAM (plan §10)
      MODEL_FILE=Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf MODEL_ALIAS=qwen3.6-35b-a3b-q4 MODEL_TITLE='Qwen3.6-35B-A3B UD-Q4_K_XL'
      MODEL_REPO=unsloth/Qwen3.6-35B-A3B-GGUF MODEL_REV=a483e9e6cbd595906af30beda3187c2663a1118c
      MODEL_BYTES=22360456160 MODEL_SHA256=707a55a8a4397ecde44de0c499d3e68c1ad1d240d1da65826b4949d1043f4450
      MODEL_SPEC=none MODEL_CACHE_RAM=8192 MODEL_NCMOE=20 MODEL_IGPU_MOE=0 MODEL_KWARGS='{"enable_thinking":true}'
      MODEL_TEMP=1.0 MODEL_TOP_P=0.95 MODEL_TOP_K=20 MODEL_MIN_P=0.0 ;;     # NCMOE=20 = fit ladder 12 Sep (15 144 MiB; k=18 UP but 500 on 1st decode)
    kat-q4)  # T1b: KAT-Coder-V2.5-Dev = Qwen3.6-35B-A3B fine-tuned for agentic coding (Kwaipilot), Q4_K_L, no MTP head
      MODEL_FILE=Kwaipilot_KAT-Coder-V2.5-Dev-Q4_K_L.gguf MODEL_ALIAS=kat-coder-v2.5 MODEL_TITLE='KAT-Coder-V2.5-Dev Q4_K_L'
      MODEL_REPO=bartowski/Kwaipilot_KAT-Coder-V2.5-Dev-GGUF MODEL_REV=d8f684f08d2950ea9d2db6a35ef7dada0707858b
      MODEL_BYTES=21768894880 MODEL_SHA256=bb0441b81a7cac064ae2fc139e6d4d0ef53dbdc8916ba117605070b7c03e455e
      MODEL_SPEC=none MODEL_CACHE_RAM=8192 MODEL_NCMOE=19 MODEL_IGPU_MOE=0 MODEL_KWARGS='{"enable_thinking":true}' MODEL_THREADS=16   # THREADS=16: 34.0 vs 25.2 t/s with 8 (sweep 13 Sep, results-t1.md §4.2); Q8 loses with 16, so per model
      MODEL_TEMP=1.0 MODEL_TOP_P=0.95 MODEL_TOP_K=20 MODEL_MIN_P=0.0 ;;     # KAT card thinking mode: temp 1.0, top_p 0.95, top_k 20; NCMOE=19 = fit ladder 13 Sep (15 267 MiB after 1st request)
    qwen35b-q8) # T1/T2 quality reference: Qwen3.6-35B-A3B Q8_0 (34.4 GiB), ~29 of 40 expert layers outside VRAM
      MODEL_FILE=Qwen3.6-35B-A3B-Q8_0.gguf MODEL_ALIAS=qwen3.6-35b-a3b-q8 MODEL_TITLE='Qwen3.6-35B-A3B Q8_0'
      MODEL_REPO=unsloth/Qwen3.6-35B-A3B-GGUF MODEL_REV=a483e9e6cbd595906af30beda3187c2663a1118c
      MODEL_BYTES=36903140320 MODEL_SHA256=d1a395809f65a43a13ad119eb4e7acdef1ac6d68120f39902c8ab96e72794a59
      MODEL_SPEC=none MODEL_CACHE_RAM=8192 MODEL_NCMOE=29 MODEL_IGPU_MOE=0 MODEL_KWARGS='{"enable_thinking":true}'
      MODEL_TEMP=1.0 MODEL_TOP_P=0.95 MODEL_TOP_K=20 MODEL_MIN_P=0.0 ;;     # NCMOE=29 fit-confirmed 13 Sep 01:04: k=27 fails, k=29 = 15 011 -> 15 064 MiB after a 4K request (results-t1.md §5.1)
    flashnext) # T2 "best" candidate: Qwen3.8-Flash-Next 125B-A6B (+51B n-gram table, MTP), UD-IQ4_XS, 3 shards = 87.3 GiB; needs llama.cpp >= b10889 (plan §4 T3 row)
      MODEL_DIR=UD-IQ4_XS MODEL_FILE=Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf MODEL_ALIAS=qwen3.8-flash-next MODEL_TITLE='Qwen3.8-Flash-Next UD-IQ4_XS'
      MODEL_REPO=unsloth/Qwen3.8-Flash-Next-GGUF MODEL_REV=38bb39ee97821de2c9009abb7e93950eec396e66
      MODEL_BYTES=10946624 MODEL_SHA256=5ce89370720f8bf90890f439361282104c1aa1482d4013bb9a50923e758e71a4
      MODEL_EXTRA='Qwen3.8-Flash-Next-UD-IQ4_XS-00002-of-00003.gguf:49835229856:577a38a2392b40ca2193cea502e1d92f60b8cd370675d308e0ec21885d9daaa7 Qwen3.8-Flash-Next-UD-IQ4_XS-00003-of-00003.gguf:43836407744:d4634e6d84f0ebb0940be15c90d3790bf6464e3dea3a1cddc567dc0e83ad8833'
      MODEL_SPEC=none MODEL_CACHE_RAM=8192 MODEL_NCMOE=all MODEL_IGPU_MOE=0 MODEL_KWARGS='{"enable_thinking":true}'
      MODEL_BIN=/data/ai/local-agent-poc/src/llama.cpp-master/build-vulkan-master/bin/llama-server   # arch needs master >= b10889 (build-vulkan-master.sh)
      MODEL_TEMP=1.0 MODEL_TOP_P=0.95 MODEL_TOP_K=20 MODEL_MIN_P=0.0 ;;     # NCMOE=all until the fit ladder; sampling = Qwen thinking defaults until the card is checked
    qwen122b) # T2 "best" candidate: Qwen3.5-122B-A10B (MTP head), UD-Q4_K_XL, 3 shards = 73.3 GiB (plan §4 T4 row)
      MODEL_DIR=UD-Q4_K_XL MODEL_FILE=Qwen3.5-122B-A10B-UD-Q4_K_XL-00001-of-00003.gguf MODEL_ALIAS=qwen3.5-122b-a10b MODEL_TITLE='Qwen3.5-122B-A10B UD-Q4_K_XL (MTP)'
      MODEL_REPO=unsloth/Qwen3.5-122B-A10B-MTP-GGUF MODEL_REV=907becb33103ab66b23da06a2dc74a5fca0583bd
      MODEL_BYTES=10943808 MODEL_SHA256=2faef922e80dcb9558c5a358510244a7c0bb96868b974a359dac87ce52a84316
      MODEL_EXTRA='Qwen3.5-122B-A10B-UD-Q4_K_XL-00002-of-00003.gguf:49667346080:874d464b62303257a152c15a3c813f65c56957eb6cf19f8ed596668235a53164 Qwen3.5-122B-A10B-UD-Q4_K_XL-00003-of-00003.gguf:28968190016:1e37527ef0e3edbbbe605956752e1be4f4bdbe4ae104701146bb33afed14244a'
      MODEL_SPEC=draft-mtp,ngram-mod MODEL_CACHE_RAM=8192 MODEL_NCMOE=all MODEL_IGPU_MOE=0 MODEL_KWARGS='{"enable_thinking":true}'
      MODEL_TEMP=1.0 MODEL_TOP_P=0.95 MODEL_TOP_K=20 MODEL_MIN_P=0.0 ;;     # Qwen3.5 thinking-mode card values; NCMOE=all until the fit ladder
    qwen122b-iq4) # T2 speed alternative of qwen122b: UD-IQ4_XS, 3 shards = 57.7 GiB
      MODEL_DIR=UD-IQ4_XS MODEL_FILE=Qwen3.5-122B-A10B-UD-IQ4_XS-00001-of-00003.gguf MODEL_ALIAS=qwen3.5-122b-a10b-iq4 MODEL_TITLE='Qwen3.5-122B-A10B UD-IQ4_XS (MTP)'
      MODEL_REPO=unsloth/Qwen3.5-122B-A10B-MTP-GGUF MODEL_REV=907becb33103ab66b23da06a2dc74a5fca0583bd
      MODEL_BYTES=10943808 MODEL_SHA256=d312417f4a5ef36ddaffcc4bbdcc47817d0c7bd27f917fa3235ad90b4805c17a
      MODEL_EXTRA='Qwen3.5-122B-A10B-UD-IQ4_XS-00002-of-00003.gguf:49754258240:5d414ef4dd2b8c73780bafa6b47deb5f5d70ecfa804a785f3b1d98a9084310de Qwen3.5-122B-A10B-UD-IQ4_XS-00003-of-00003.gguf:12162581376:d9ac8af93d3818980762fdfb18d4ff30415d37233acba156995bfb816819bcf9'
      MODEL_SPEC=draft-mtp,ngram-mod MODEL_CACHE_RAM=8192 MODEL_NCMOE=all MODEL_IGPU_MOE=0 MODEL_KWARGS='{"enable_thinking":true}'
      MODEL_TEMP=1.0 MODEL_TOP_P=0.95 MODEL_TOP_K=20 MODEL_MIN_P=0.0 ;;
    *) echo "unknown model '$1' (profiles: vram|t0|fastest-vram = qwen35b  T1 candidates: qwen35b-q4|kat-q4|qwen35b-q8  T2 candidates: flashnext|qwen122b|qwen122b-iq4)" >&2; return 1 ;;
  esac
}
