#!/bin/sh
# build-vulkan-2.sh - build the patched llama.cpp (patches/0001-vulkan-chunk-staging-transfers.patch)
# into a SEPARATE build dir, so the running server's build-vulkan/ .so files are never touched.
# Same configuration as build-vulkan (Ninja, Release, shared libs, ccache, -DGGML_VULKAN=ON).
# Run only when no E2E task / GPU work is running (shader compilation is CPU-heavy, ~3-8 min).
set -eu
SRC=/data/ai/local-agent-poc/src/llama.cpp
B=${B:-$SRC/build-vulkan-2}
J=${J:-$(sysctl -n hw.ncpu)}
cd "$SRC"
git apply --check /data/local-ai/asgard/patches/0001-vulkan-chunk-staging-transfers.patch 2>/dev/null \
  && git apply /data/local-ai/asgard/patches/0001-vulkan-chunk-staging-transfers.patch
grep -q GGML_VK_STAGING_CHUNK_MB ggml/src/ggml-vulkan/ggml-vulkan.cpp || { echo "patch not applied"; exit 1; }
cmake -S "$SRC" -B "$B" -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON -DGGML_VULKAN=ON \
  -DGGML_NATIVE=ON -DGGML_CCACHE=ON -DGGML_OPENMP=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_OPENSSL=ON -DCMAKE_PREFIX_PATH=/data/ai/local-agent-poc/opt/spirv-headers -DCMAKE_CXX_FLAGS=-I/data/ai/local-agent-poc/opt/spirv-headers/include
nice -n ${NICE:-19} cmake --build "$B" -j "$J" --target llama-server
ls -la "$B/bin/llama-server" "$B/bin/libggml-vulkan.so"
echo "done: point serve.sh B= at $B/bin (and keep build-vulkan as the fallback)"
