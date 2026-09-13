#!/bin/sh
# build-vulkan-master.sh - build a llama.cpp MASTER release tag (T2/Qwen3.8-Flash-Next needs >= b10889; plan §5) from the
# git worktree ../llama.cpp-master into build-vulkan-master, with the same chunked-staging patch
# (patches/0001-vulkan-chunk-staging-transfers.patch) and the same cmake configuration as build-vulkan-2.sh.
# The v0.4.0 tree (build-vulkan / build-vulkan-2, the T0 profile's binary) is never touched.
#   TAG=b11020 ./build-vulkan-master.sh     (default: the newest b* tag already fetched; `git fetch --tags origin` first)
# Run only when no E2E task / GPU work is running (shader compilation is CPU-heavy, ~5-10 min at nice 19).
set -eu
POC=/data/ai/local-agent-poc/src/llama.cpp
SRC=${SRC:-$POC/../llama.cpp-master}
B=${B:-$SRC/build-vulkan-master}
J=${J:-$(sysctl -n hw.ncpu)}
PATCH=/data/local-ai/asgard/patches/0001-vulkan-chunk-staging-transfers.patch
TAG=${TAG:-$(git -C "$POC" tag -l 'b*' | sort -V | tail -1)}
if [ ! -d "$SRC" ]; then git -C "$POC" worktree add "$SRC" "$TAG"; fi
cd "$SRC"
cur=$(git describe --tags --always)
if [ "$cur" != "$TAG" ]; then git checkout -q -- . 2>/dev/null || true; git checkout -q --detach "$TAG"; fi
git apply --check "$PATCH" 2>/dev/null && git apply "$PATCH"
grep -q GGML_VK_STAGING_CHUNK_MB ggml/src/ggml-vulkan/ggml-vulkan.cpp || { echo "patch not applied"; exit 1; }
echo "building $(git describe --tags --always) -> $B"
cmake -S "$SRC" -B "$B" -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON -DGGML_VULKAN=ON \
  -DGGML_NATIVE=ON -DGGML_CCACHE=ON -DGGML_OPENMP=OFF -DLLAMA_BUILD_TESTS=ON -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_OPENSSL=ON -DCMAKE_PREFIX_PATH=/data/ai/local-agent-poc/opt/spirv-headers -DCMAKE_CXX_FLAGS=-I/data/ai/local-agent-poc/opt/spirv-headers/include
nice -n ${NICE:-19} cmake --build "$B" -j "$J" --target llama-server test-backend-ops
ls -la "$B/bin/llama-server" "$B/bin/libggml-vulkan.so" "$B/bin/test-backend-ops"
"$B/bin/llama-server" --version 2>&1 | head -2
echo "done: models.sh MODEL_BIN=$B/bin/llama-server (flashnext) or B=$B/bin/llama-server ./start.sh MODEL; build-vulkan-2 stays the default"
