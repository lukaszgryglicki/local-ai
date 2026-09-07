# local-ai

Qwen3-Coder-30B-A3B-Instruct Q8_0 (30.25 GiB GGUF) served locally by llama.cpp
(fork, LLAMA_REF v0.4.0) on this laptop: Ryzen 7 8845HS, Radeon 780M iGPU,
61.75 GiB DDR5, FreeBSD 15.1, ZFS, no swap.

## What runs where

- Context 262144 (256K), parallel=1 (one client at a time; 2x256K slots would
  need ~58 GiB and cannot fit).
- KV cache q8_0/q8_0 + flash-attn: 12.75 GiB (f16 would be 24 GiB - impossible).
- Server RSS ~43 GiB total (weights 30.25 + KV 12.75 + buffers).
- GPU: BIOS VRAM carve-out is only 2048 MiB; the "21.9 GiB device-local" heap
  RADV reports is carve-out + GTT (shared system RAM, ~31.6 GiB budget). Every
  GPU byte is a wired host-RAM byte at the same DDR5 speed.
  GPU offload setting: see serve.sh (--gpu-layers); KV stays in system RAM
  (--no-kv-offload) so amdgpu command submission survives memory pressure.
- Measured speed (20.7K-token prompt, full 256K ctx): input 121 tok/s;
  output ~10 tok/s shallow, ~5 tok/s fresh text at 20K depth, 12-35 tok/s on
  echo-heavy output (file edits) thanks to ngram self-speculation (lossless).
  Key levers (already set in serve.sh, do not change): --threads 12 (16/SMT
  collapses output to 1.4 tok/s), --ubatch-size 1024 (2048 crashes the GPU at
  256K), --spec-type ngram-simple.
- Load ~47-60 s (cold NVMe read, ~700 MB/s).

## Why the model lives on its own ZFS dataset

zroot/data/local-ai (this dir), primarycache=metadata, compression=off.
Without it every load double-buffered 30 GiB into ZFS ARC (mmap and plain
read() alike; O_DIRECT silently falls back on unaligned reads), free RAM
collapsed and the box OOM-froze. With it ARC stays flat during loads.
model.gguf here is the real file (BRT block-clone); the POC path symlinks to it.
Note: ./llama is a small launcher whose libraries load (via RUNPATH) from
/data/ai/local-agent-poc/src/llama.cpp/build-vulkan/bin - keep that dir.

## Run

FreeBSD host:

    ./serve.sh &        # ready when http://10.253.254.1:18080/health is ok
    ./health.sh         # checks server is up AND the model generates
    ./qwen.sh           # interactive qwen agent; or ./qwen.sh -p "task"

bhyve VM (ubuntu, this dir = /freebsd/data/local-ai):

    ./copilot.sh        # interactive copilot; or ./copilot.sh -p "task"

Stop server:

    kill $(pgrep -f local-ai/llama)

parallel=1: run ONE client at a time or the second waits forever.
