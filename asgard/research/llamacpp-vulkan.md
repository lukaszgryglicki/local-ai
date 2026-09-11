Agent is idle (waiting for messages). agent_id: 4bf5dbd8-7e97-455d-984d-91605c43078a, agent_type: research, status: idle, description: Research llama.cpp Vulkan MoE offload, elapsed: 1074s, total_turns: 1

[Turn 0]
# llama.cpp (Sept 2026) — hybrid MoE on FreeBSD 15 + Vulkan (Quadro RTX 5000 16 GiB + Xeon W-10885M/128 GiB DDR4)

## Summary

Verified against `ggml-org/llama.cpp` master (build b10909, 2026‑09‑11) and the release feed. Big changes vs. 2025 lore: (a) llama.cpp now has **semver stable tags** (`v0.4.0`, 2026‑09‑04) alongside nightly `b####` tags; (b) `-ngl` defaults to **`auto`** with **`--fit on`** by default, which automatically pushes MoE expert tensors to CPU when VRAM is short; (c) `--no-mmap`/`--mlock` were **removed/renamed into `--load-mode`** (PR #20834); (d) `--chat-template-kwargs '{"enable_thinking":…}'` is **deprecated** in favour of `--reasoning on|off|auto`; (e) speculative decoding is unified under `--spec-type` with `draft-mtp` (MTP merged), `ngram-mod`, etc.; (f) `--split-mode` gained `tensor` (experimental). Vulkan on the RTX 5000 will use **NV_coopmat2** (matmul + FA), FA supports **q8_0 KV**, and Vulkan does **not** silently spill to host RAM by default — allocation fails unless `GGML_VK_ALLOW_SYSMEM_FALLBACK` is set. The Intel iGPU is **auto‑excluded** when a discrete GPU exists. The FreeBSD `misc/ggml`/`misc/llama-cpp` packages are built **without AVX2/FMA/F16C**, so a source build with `-DGGML_NATIVE=ON` is essential for CPU‑side experts. One open FreeBSD‑specific NVIDIA Vulkan hang issue (#15996) exists.

---

## 1. Current CLI flags (from `common/arg.cpp`, master b10909)

Source: https://github.com/ggml-org/llama.cpp/blob/master/common/arg.cpp ; server table: https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md

| Flag | Current help text / semantics | Notes |
|---|---|---|
| `-cmoe, --cpu-moe` | "keep all Mixture of Experts (MoE) weights in the CPU" — pushes override `{LLM_FFN_EXPS_REGEX, cpu_buft}` (`arg.cpp:2756-2761`) | Regex in `common.h:1131`: `"\\.ffn_(up|down|gate|gate_up)_(ch|)exps"` (also matches `gate_up_exps` and `_chexps`). PR #14992 https://github.com/ggml-org/llama.cpp/pull/14992 |
| `-ncmoe, --n-cpu-moe N` | "keep the MoE weights of the first N layers in the CPU" → adds N overrides `blk\.<i>\.ffn_(up|down|gate|gate_up)_(ch|)exps=CPU` for i=0..N‑1 (`common.h:1143-1150`) | PR #15077 https://github.com/ggml-org/llama.cpp/pull/15077 |
| `-ncffn, --n-cpu-ffn N` | NEW (v0.4.0, PR #26622): "keep the dense FFN weights of the first N layers in the CPU (dense models; for MoE expert weights use --n-cpu-moe)"; regex `\.ffn_(up|down|gate)\.` | |
| `-ot, --override-tensor <pattern>=<buftype>,...` | "override tensor buffer type"; comma‑separated list; pattern is a `std::regex` matched against tensor names; buffer type must match a name from `--list-devices` output (`CPU`, `Vulkan0`, `Vulkan1`, `Vulkan_Host`…) — unknown name prints "Available buffer types:" and aborts (`arg.cpp:252-284`) | Original PR #11397 https://github.com/ggml-org/llama.cpp/pull/11397. Example: `-ot 'blk\.([0-9]|1[0-9])\.ffn_.*_exps=CPU'` (quote so shell doesn't eat `\`). Env `LLAMA_ARG_OVERRIDE_TENSOR`. |
| `-ngl, --gpu-layers, --n-gpu-layers N` | "max. number of layers to store in VRAM, either an exact number, **'auto'**, or **'all'** (default: auto)" (`arg.cpp:2785-2801`); `-1`=auto, `-2`=all (`common.h:473`) | `99` still works as "all". |
| `-fit, --fit [on|off]` | "whether to adjust unset arguments to fit in device memory" (default **on**, `common.h:476`); `--fit-target MiB` margin per device (default 1024 MiB), `--fit-ctx N` min ctx (default 4096) | `common/fit.cpp:489`: "for a MoE model, same as dense model but with all MoE tensors in system memory" — i.e. auto mode = all layers on GPU, experts on CPU, then fills VRAM. **Aborts fit if you pass `-ot`/`--tensor-split` yourself** (`fit.cpp:470-485`). `--fit` refuses `split-mode row`. |
| `-nkvo, --no-kv-offload` / `-kvo, --kv-offload` | "whether to enable KV cache offloading (default: enabled)" (`arg.cpp:2411-2417`) | For your case keep KV in VRAM (default). |
| `-sm, --split-mode {none,layer,row,tensor}` | none: one GPU; **layer (default)**: split layers and KV across GPUs (pipelined); row: split weights by rows; **tensor**: split weights and KV (parallelized, EXPERIMENTAL, added v0.3.0 PR #26490) (`arg.cpp:2803-2825`) | |
| `-ts, --tensor-split N0,N1,...` | "fraction of the model to offload to each GPU, comma‑separated list of proportions, e.g. 3,1" (`arg.cpp:2827`) | If omitted: split by **free memory** (`src/llama-model.cpp:1462-1476`). |
| `-mg, --main-gpu INDEX` | "the GPU to use for the model (with split-mode = none), or for intermediate results and KV (with split-mode = row) (default: 0)" | |
| `-dev, --device <dev1,dev2,..>` | "comma‑separated list of devices to use for offloading (none = don't offload)"; names resolved via `ggml_backend_dev_by_name`; `CPU` rejected (`arg.cpp:1116-1136, 2734-2740`) | Vulkan device names are `Vulkan0`, `Vulkan1`… (`ggml-vulkan.cpp:19976`). Env `LLAMA_ARG_DEVICE`. |
| `--list-devices` | "print list of available devices and exit" (non‑CPU only) | |
| `-fa, --flash-attn [on|off|auto]` | default **auto** (`common.h:499`) | |
| `-ctk/-ctv, --cache-type-k/v TYPE` | "KV cache data type for K/V", default f16; `q8_0` valid | Vulkan FA supports q8_0 KV — see §2. |
| `-b, --batch-size N` | "logical maximum batch size (default: 2048)"; `-ub, --ubatch-size N` "physical maximum batch size (default: 512)" | |
| `-t, --threads N` (gen) / `-tb, --threads-batch N` (pp, default = threads) | | For 8C/16T, try `-t 8` (physical cores) for tg; `-tb 16` for pp. |
| `-np, --parallel N` | server: "number of server slots (default: 1, -1 = auto)"; `-kvu/--kv-unified` "single unified KV buffer... (default: enabled if number of slots is auto)" | |
| `-c, --ctx-size N` | "size of the prompt context (default: 0, 0 = loaded from model)"; `-c 0` disables fit's ctx reduction (`arg.cpp:1636-1645`) | |
| `-lm, --load-mode MODE` | **replaces `--no-mmap`/`--mlock`** (PR #20834 merged 2026‑07‑23; auto default PR #26081): `auto` (mmap unless a device doesn't support it), `none`, `mmap`, `mlock`, `mmap+mlock`, `dio` (DirectIO) (`arg.cpp:2686-2704`) | `--no-mmap` ≈ `--load-mode none`; `--mlock` ≈ `--load-mode mlock`. `--no-mmap`/`--mlock` strings no longer appear in `arg.cpp`. |
| `-lzm, --lazy-mode on/auto/off` | on‑demand reading of huge per‑layer tensors (>4 GiB in auto) (v0.4.0, PR #27794/#27969) | |
| `--numa distribute|isolate|numactl` | unchanged | Single‑socket W‑10885M: not needed. |
| `--jinja` / `--no-jinja` | "whether to use jinja template engine for chat (default: **enabled**)" (`common.h:638`) | |
| `--reasoning-format none|deepseek|deepseek-legacy` (default auto) | controls extraction of thoughts into `message.reasoning_content` (`arg.cpp:3666-3676`) | |
| `-rea, --reasoning on|off|auto` | "Use reasoning/thinking in the chat (default auto, detect from template)"; sets `enable_thinking` template kwarg (`arg.cpp:3677-3695`) | **Replaces** `--chat-template-kwargs '{"enable_thinking":true}'`, which now logs "deprecated... Use --reasoning on / --reasoning off" (`arg.cpp:3521-3532`). Also `--reasoning-effort LEVEL`, `--reasoning-preserve` (default on since #28174). |
| `--reasoning-budget N` | "token budget for thinking: -1 unrestricted, 0 immediate end, N>0 budget (default: -1)"; `--reasoning-budget-message` | |
| `--spec-type T1,T2` | types: `none, draft-simple, draft-eagle3, draft-mtp, draft-dflash, draft-dspark, ngram-simple, ngram-map-k, ngram-map-k4v, ngram-mod, ngram-cache` (`speculative.cpp:33-45`); `--spec-default` enables ngram-mod | docs: https://github.com/ggml-org/llama.cpp/blob/master/docs/speculative.md ; ngram-mod PR #19164 https://github.com/ggml-org/llama.cpp/pull/19164 |
| `--spec-type draft-mtp` | "Use Multi Token Prediction (MTP) heads from the main model" — auto‑detected from `blk.<last>.nextn.eh_proj.weight` in the GGUF (`speculative.cpp:2290-2314`); creates an MTP context against the target model, no separate draft needed (`speculative.cpp:2538-2589`); MTP head can also be a sidecar GGUF via `-md` | `--mtp` flag is **download‑only** ("also download the MTP head, if available", `arg.cpp:3080`). GLM‑4.5‑Air MTP added v0.3.0 (PR #26534); Qwen3.5/qwen35moe single head (`speculative.cpp:1345`). |
| `-md, --model-draft, --spec-draft-model FNAME` ; `--spec-draft-n-max` (alias `--draft-max`, `--draft`, default 3); `--spec-draft-n-min` (`--draft-min`); `--spec-draft-p-min` (`--draft-p-min`); `-ngld`; `-devd/--device-draft`; `-cmoed/--cpu-moe-draft`; `-ncmoed/--n-cpu-moe-draft`; `-otd/--override-tensor-draft` | (`arg.cpp:4103-4245`; draft variants PR #15191) | |
| ngram‑mod knobs | `--spec-ngram-mod-n-match 24 --spec-ngram-mod-n-min 48 --spec-ngram-mod-n-max 64` (defaults, `common.h:353-357`); docs note "MoEs require long drafts" | |
| `--op-offload/--no-op-offload` | "whether to offload host tensor operations to device (default: true)" | Governs pp behaviour for CPU‑resident experts (§3). |
| `--no-host`, `--no-repack` | bypass host buffer / disable CPU weight repacking | |

Example (server, all flags current):
```sh
GGML_VK_VISIBLE_DEVICES=<nvidia-physical-index> llama-server -m model.gguf \
  --device Vulkan0 -ngl all --n-cpu-moe 40 -fa on -ctk q8_0 -ctv q8_0 \
  -c 65536 -b 2048 -ub 512 -t 8 -tb 16 --load-mode mlock \
  --jinja --reasoning on --reasoning-budget 4096 --reasoning-format deepseek \
  --spec-type ngram-mod --parallel 1 --fit off
```
(or omit `--n-cpu-moe/-ot` and let the default `-ngl auto --fit on` place experts automatically).

## 2. Vulkan backend specifics (`ggml/src/ggml-vulkan/ggml-vulkan.cpp`, 20,948 lines)

- **Architecture detection**: NVIDIA with `VK_KHR_cooperative_matrix` and `shaderWarpsPerSM==32` → `NVIDIA_TURING` (`ggml-vulkan.cpp:505-534`). Your TU104 is exactly this.
- **coopmat2**: enabled when `VK_NV_cooperative_matrix2` present, features `WorkgroupScope/FlexibleDimensions/Reductions/Conversions/PerElementOperations/TensorAddressing/BlockLoads` all true and fp16/fp32 128/256‑invocation shapes found (`:6591-6593, 7150-7157, 7645-7652`). **Compile‑time gated** by `GGML_VULKAN_COOPMAT2_GLSLC_SUPPORT` — CMake tests glslc for `GL_NV_cooperative_matrix2` (`ggml/src/ggml-vulkan/CMakeLists.txt:72-97`); FreeBSD `graphics/shaderc` is 2026.3, new enough.
- **MUL_MAT / MUL_MAT_ID supported weight types** (`:19203-19246`): F32/F16/BF16, Q1_0, Q2_0, Q4_0/1, Q5_0/1, Q8_0, Q2_K…Q6_K, IQ1_S/M, IQ2_*, IQ3_*, IQ4_XS, IQ4_NL, MXFP4, NVFP4, TQ1_0/2_0. All go through coopmat2 dequant tiles for pp; for tg (n=1) the MMVQ integer‑dot path is chosen on NVIDIA for k>4096 for most quants, but **Q8_0 and MXFP4 use MMVQ only on pre‑Turing** and **Q6_K never uses MMVQ except on Intel** (`ggml_vk_should_use_mmvq`, `:9703-9739`). So Q4_K/Q5_K/IQ4_XS get the integer‑dot fast path on Turing; Q6_K/Q8_0 use the f16 mat‑vec path. Env: `GGML_VK_FORCE_MMVQ`/`GGML_VK_DISABLE_MMVQ`.
- **Flash attention**: path = `coopmat2 ? FA_COOPMAT2 : coopmat1_fa ? FA_COOPMAT1 : FA_SCALAR`; **coopmat1 FA is disabled on Turing** due to an NVIDIA compiler bug (PR #19290 https://github.com/ggml-org/llama.cpp/pull/19290, `:4072-4075`); for `n_rows==1` (single‑token decode) the scalar path is used regardless (`:4088-4091`). **KV types accepted by FA**: F32, F16, BF16, **Q8_0**, Q5_1, Q5_0, Q4_1, Q4_0, IQ4_NL (`:19290-19305`) → `-fa on -ctk q8_0 -ctv q8_0` works. v0.2.0 note: "vulkan : dequant q8_0 KV once in coopmat1 (#25494)".
- **Env vars** (all `getenv` in `ggml-vulkan.cpp`): `GGML_VK_VISIBLE_DEVICES`, `GGML_VK_DISABLE_COOPMAT`, `GGML_VK_DISABLE_COOPMAT2`, `GGML_VK_DISABLE_COOPMAT2_DECODE_VECTOR`, `GGML_VK_DISABLE_F16`, `GGML_VK_DISABLE_BFLOAT16`, `GGML_VK_DISABLE_INTEGER_DOT_PRODUCT`, `GGML_VK_DISABLE_DOT2`, `GGML_VK_DISABLE_OCP_FP4`, `GGML_VK_FORCE_MAX_ALLOCATION_SIZE`, `GGML_VK_FORCE_MAX_BUFFER_SIZE`, `GGML_VK_SUBALLOCATION_BLOCK_SIZE`, `GGML_VK_PREFER_HOST_MEMORY`, `GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM`, `GGML_VK_ALLOW_SYSMEM_FALLBACK`, `GGML_VK_ENABLE_MEMORY_PRIORITY` (uses `VK_EXT_memory_priority`, `:6621-6623`), `GGML_VK_DISABLE_FUSION`, `GGML_VK_DISABLE_GRAPH_OPTIMIZE`, `GGML_VK_DISABLE_ASYNC`, `GGML_VK_ASYNC_USE_TRANSFER_QUEUE`, `GGML_VK_MAX_NODES_PER_SUBMIT`, `GGML_VK_PERF_LOGGER`, `GGML_VK_MEMORY_LOGGER`, `GGML_VK_SYNC_LOGGER`, `GGML_VK_PIPELINE_STATS`, `GGML_OP_OFFLOAD_MIN_BATCH` (default 32).
- **Allocation limits**: `max_memory_allocation_size = min(maxMemoryAllocationSize, maxBufferSize)` (maintenance4), overridable with `GGML_VK_FORCE_MAX_ALLOCATION_SIZE`; suballocation block default **1 GiB** ("to avoid fragmentation"), `GGML_VK_SUBALLOCATION_BLOCK_SIZE` (`:6714-6742`).
- **Host‑visible heap behaviour** (`ggml_vk_create_buffer_device`, `:3794-3831`): default for a discrete GPU tries `{DeviceLocal|HostVisible|HostCoherent}` (ReBAR) then `{DeviceLocal}`; **no host‑RAM fallback** unless `GGML_VK_ALLOW_SYSMEM_FALLBACK` is set (then a third attempt `{HostVisible|HostCoherent}` in heap1). On failure it prints `ggml_vulkan: Device memory allocation of size N failed.` + the `vk::OutOfDeviceMemoryError` and rethrows → model load fails (not DeviceLost). `GGML_VK_PREFER_HOST_MEMORY` inverts the order (host first). Caveat: the NVIDIA driver itself may page with `VK_EXT_pageable_device_local_memory`; llama.cpp only requests device‑local, so any silent slowness would be driver‑side, not llama.cpp‑side.
- **Memory reporting** (`ggml_backend_vk_get_device_memory`, `:18979-19010`): discrete GPU → only DeviceLocal heaps (your 16 GiB), using `VK_EXT_memory_budget` if available; **integrated GPU → sums all heaps** (Intel P630 would report ~all of system RAM as free — matters for default tensor split / `--fit` if you ever include it).
- **Turing Vulkan vs CUDA (same chips)** — Vulkan scoreboard https://github.com/ggml-org/llama.cpp/discussions/10879 vs CUDA scoreboard https://github.com/ggml-org/llama.cpp/discussions/15013 (Llama‑2‑7B Q4_0, pp512/tg128):
  - RTX 2080 Ti: Vulkan 1888/97.6 (no FA), 1936/101.0 (FA) vs CUDA 2891/107.5, 3108/109.2 → Vulkan ≈ 62–65% pp, ≈ 91–93% tg.
  - RTX 2070 Super (**448 GB/s, same bandwidth as your Quadro RTX 5000**): Vulkan 1199/64.6 vs CUDA 2088/88.1 (older Vulkan commit b7552cf) → expect roughly **60–75 t/s tg** on 7B‑Q4_0‑class dense work and ~1.2–1.5k pp512 for the RTX 5000 mobile.
  - Newer datapoint (Vulkan tg near CUDA on GB10): https://forums.developer.nvidia.com/t/vulkan-as-alternative-backend-for-llama-cpp/363516 ; "Performance VULKAN vs CUDA" https://github.com/ggml-org/llama.cpp/discussions/23109 (2026‑05; on a GT1030 Vulkan tg beat CUDA, pp lost) — anecdotal.
  - Open regression thread "Vulkan: performance drop in recent builds" https://github.com/ggml-org/llama.cpp/issues/24066 (2026‑06 → 08, mostly AMD, includes a FreeBSD 16 tester) — pin a version and benchmark.

## 3. Heterogeneous Vulkan multi‑GPU (NVIDIA + Intel iGPU)

- **Default device list excludes iGPUs when a dGPU exists**: `src/llama.cpp:260-285` — "add integrated GPUs only if no discrete GPUs were found". Vulkan reports the P630 as `GGML_BACKEND_DEVICE_TYPE_IGPU` (`ggml-vulkan.cpp:19100-19104`). So with default args only the RTX 5000 is used; llvmpipe (`eCpu` type) is skipped by the Vulkan backend unless no GPU exists (`:7813-7822, 7911-7920`).
- **Selecting only NVIDIA**: `--device Vulkan0` (names are index‑ordered after backend filtering/dedup) or `GGML_VK_VISIBLE_DEVICES=<i>` where `<i>` is the **raw `vkEnumeratePhysicalDevices` index** (same order as `vulkaninfo`), including llvmpipe (`:7789-7805`). Check with `llama-server --list-devices`.
- **Cross‑vendor `--split-mode layer` + `--tensor-split` works** (both devices are the same ggml backend; scheduler is device‑agnostic). But the P630 shares your DDR4 (~40 GB/s), has no coopmat, subgroup 8, and would only add a PCIe/UMA copy per layer; expert mat‑vec bandwidth is identical to CPU while compute is much weaker than 8 AVX2 cores. No benchmark for P630 exists in #10879 (only Arc entries); build docs show an Intel ADL GT2 detection line only (docs/build.md ~line 524). Expectation (inferred): **iGPU slower than or equal to CPU for experts** — keep experts on CPU. Also `props.caps.mmap_support = !is_integrated_gpu` (`:19116`) → `--load-mode auto` disables mmap if you include the iGPU (PR #26081).
- **Scheduler behaviour for CPU‑resident experts** (`ggml/src/ggml-backend.cpp:921-984`): ops whose weights live in a host buffer run on the CPU backend, **except** when `op_offload` is on and a higher‑priority backend's `offload_op` returns true — Vulkan's returns `batch_size >= GGML_OP_OFFLOAD_MIN_BATCH (32)` (`ggml-vulkan.cpp:19807-19811, 19970`). So: **tg (1 token) → experts computed on CPU, only activations (hidden state, ~n_embd×4 B) cross PCIe per layer per token; pp (ubatch ≥ 32) → expert weights are streamed over PCIe to the GPU each ubatch** (bandwidth‑bound on PCIe 3.0 x16 ≈ 12–14 GB/s), which is why hybrid pp is far slower than full‑VRAM pp; `--no-op-offload` forces pp experts onto CPU instead.

## 4. Performance model for hybrid MoE

Per generated token (bandwidth‑bound, batch 1):

```
t_tok ≈ B_exp_cpu / BW_RAM  +  B_dense_gpu / BW_VRAM  +  B_kv(ctx) / BW_VRAM  +  n_layer·t_sync
B_exp_cpu   = n_layer_cpu_moe · n_expert_used · (3 · n_embd · n_ff_exp) · bytes/param   (gate+up+down; 2 if gate_up fused)
B_dense_gpu = attention + shared‑expert + router + embeddings/output params on GPU · bytes/param
B_kv(ctx)   = 2 · n_layer · n_kv_head · head_dim · ctx · bytes_kv   (f16 = 2 B, q8_0 ≈ 1.06 B)
tg ≈ 1 / t_tok
```
With your DDR4‑2933 dual‑channel (theoretical 46.9 GB/s, STREAM realistically ~35–42 GB/s), an "A3B" model at Q4_K_M (~0.58 B/param) streams ≈1.7–1.9 GB of experts/token → **RAM term ≈ 40–50 ms ⇒ ceiling ≈ 20–25 t/s**; A10B (Qwen3.5‑122B‑A10B Q4) ≈ 5.5–6 GB/token → **≈ 7–8 t/s** ceiling; gpt‑oss‑120b (A5.1B, MXFP4 ≈ 0.53 B/param, ~2.7 GB/token) → **≈ 13–15 t/s** ceiling. The VRAM term is small (<1–3 ms) while KV+dense fit in 16 GiB. Per‑layer host↔device syncs add ~0.05–0.2 ms each (tens of layers ⇒ few ms). Real results typically land at 60–80% of the RAM ceiling.

Anecdotal measured hybrids (all CUDA/ROCm/Vulkan mixes; treat as ballpark):
- RTX 3060 12 GB + Ryzen 5700X/32 GB DDR4, gpt‑oss‑20b, `-ncmoe 2..3` or `-ot '\.([2-9][0-9])\.ffn_up_exps.=CPU'`: 53–67 t/s tg — https://github.com/ggml-org/llama.cpp/discussions/15396#discussioncomment-14145339
- RTX 4060 Laptop 8 GB + i7‑14700HX/64 GB DDR5‑5200, gpt‑oss‑20b MXFP4, `--n-cpu-moe 14`: tg128 42 t/s, pp2048 1642 t/s — https://github.com/ggml-org/llama.cpp/discussions/15396#discussioncomment-14923651
- RTX 4070 (Vulkan!) + DDR5‑4800, gpt‑oss‑20b F16, `--n-cpu-moe 5`: tg128 33.7 t/s, pp2048 ~1040 t/s — https://github.com/ggml-org/llama.cpp/discussions/15396#discussioncomment-14533592
- GTX 1080 Ti 11 GB, Qwen3.6‑35B‑A3B Q8_K_XL, `--cpu-moe`: 19.3 t/s — https://github.com/ggml-org/llama.cpp/discussions/24528#discussioncomment-17300801
- RX 6700 XT 12 GB + 16 GB DDR4‑2400, gpt‑oss‑20b without offload (driver paging): 80 t/s → 19 t/s at ~21k ctx — https://github.com/ggml-org/llama.cpp/discussions/15396#discussioncomment-14266870
- Scaling evidence: 4‑ch→8‑ch DDR4 (STREAM 57→100 GB/s) — RFC https://github.com/ggml-org/llama.cpp/discussions/24528#discussioncomment-17899247 (CUDA MoE expert‑cache RFC, not available on Vulkan).
- **tg decay vs context** (KV in VRAM, FA on): M4 Max gpt‑oss‑20b tg 94 → 88 (2k) → 82 (8k) → 77 (16k) → 65 t/s (32k) — https://github.com/ggml-org/llama.cpp/discussions/15396 (guide tables). With KV in VRAM the decay is the `B_kv/BW_VRAM` term (mild, ~1.5x by 32k); if attention ran on CPU (`--no-kv-offload`) the same KV traffic hits the ~40 GB/s RAM bus and decay is ~10x steeper — keep KV on GPU and use `q8_0` KV to halve it.
- No hybrid table specifically for Qwen3‑Coder‑Next‑80B‑A3B / Qwen3.5‑122B‑A10B / GLM‑4.7‑Flash on 16 GB + DDR4 was found on GitHub (searched discussions; #21154 is ROCm‑only). Apply the formula above.

## 5. Recommended version and FreeBSD build

- **Versioning**: since `v0.2.0` (2026‑08‑21) llama.cpp publishes semver "stable" tags; `b####` tags are nightlies (https://github.com/ggml-org/llama.cpp/releases/tag/v0.2.0 ; policy https://github.com/ggml-org/ggml/discussions/1579). Latest stable: **`v0.4.0` (2026‑09‑04)** https://github.com/ggml-org/llama.cpp/releases/tag/v0.4.0 — includes Qwen3.8‑Flash‑Next (`qwen4exp`), `--n-cpu-ffn`, `--lazy-mode`, ggml 0.23.0, Vulkan fixes (FA dequant path #28190, bf16 ext only if supported #28155, IQ3_S mat‑vec #27449). `v0.3.0` (2026‑08‑25) added GLM‑4.5‑Air MTP and `-sm tensor`. Qwen3‑Next/Qwen3.5 (incl. MTP) and ngram‑mod (Jan 2026, #19164) are all older than v0.2.0. Recommendation: **`v0.4.0`** (or a nightly ≥ b10900 if you need a fix), and check #24066 if tg looks low.
- **Vulkan requirements** (`docs/build.md` §Vulkan): `-DGGML_VULKAN=ON`, `glslc` (shaderc), Vulkan headers/loader, and **SPIRV‑Headers** ("required... not always pulled in by the loader dev package", build.md ~line 502); `ggml-vulkan/CMakeLists.txt:9,14`: `find_package(Vulkan COMPONENTS glslc REQUIRED)`, `find_package(SPIRV-Headers CONFIG REQUIRED)`.
- **FreeBSD ports state** (freebsd/freebsd-ports main): `misc/llama-cpp` = **b10900** (updated 2026‑09‑10, commit 3b90c2e98) using `LLAMA_USE_SYSTEM_GGML` → `misc/ggml` 0.23.0‑38 with `OPTIONS_DEFAULT=VULKAN` (deps `graphics/shaderc` 2026.3, `graphics/vulkan-headers` 1.4.360, `graphics/spirv-headers` 1.4.357, `graphics/vulkan-loader`). **But** `misc/ggml` sets `CMAKE_OFF= GGML_NATIVE GGML_SSE42 GGML_AVX GGML_AVX2 GGML_BMI2 GGML_FMA GGML_F16C` and `misc/llama-cpp` patches ggml‑cpu to only emit ISA flags if `FREEBSD_ALLOW_ADVANCED_CPU_FEATURES` (off) → the packaged CPU backend is baseline x86‑64 — unacceptable for CPU‑side experts. Sources: https://github.com/freebsd/freebsd-ports/blob/main/misc/ggml/Makefile , https://github.com/freebsd/freebsd-ports/blob/main/misc/llama-cpp/Makefile , https://github.com/freebsd/freebsd-ports/blob/main/misc/llama-cpp/files/patch-ggml_src_ggml-cpu_CMakeLists.txt
- **Recommended source build (FreeBSD 15, clang, Vulkan, native AVX2)**:
```sh
pkg install cmake ninja shaderc vulkan-headers vulkan-loader spirv-headers curl git   # glslc comes from shaderc
git clone --branch v0.4.0 --depth 1 https://github.com/ggml-org/llama.cpp && cd llama.cpp
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
  -DGGML_VULKAN=ON -DGGML_NATIVE=ON -DLLAMA_CURL=ON \
  -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF
cmake --build build --config Release -j 16
build/bin/llama-server --list-devices   # expect: Vulkan0: NVIDIA Quadro RTX 5000 (16384 MiB, ... free)
```
  CMake will print "GL_NV_cooperative_matrix2 supported by glslc" etc. (`ggml-vulkan/CMakeLists.txt:45-49`). Optionally `-DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=ON` for a portable binary (docs/build.md ~line 845).
- **FreeBSD‑specific issues**: open **#15996 "Vulkan backend hangs forever with NVIDIA GPU on FreeBSD"** (RTX 5090, driver 580.82.07, FreeBSD 14.3; jeffbolznv filed an internal NVIDIA bug on the sync‑staging buffer allocation; still open, no fix recorded) https://github.com/ggml-org/llama.cpp/issues/15996 — test early with `test-backend-ops -b Vulkan0` on 595.99.02. A FreeBSD 16 user runs 7900 XTX Vulkan fine (#24066 comment 2026‑08‑15). Historical FreeBSD notes in the port: some tests segfault (#11036, #11705).

## Gaps / uncertainties
- No published benchmark for Quadro RTX 5000 (mobile) specifically; RTX 2070 Super (same 448 GB/s) used as proxy.
- Vulkan vs CUDA figures come from two community scoreboards at different commits; treat ratios as ±15%.
- No GitHub data for the Intel UHD P630 as a Vulkan compute device; "slower than CPU for experts" is inferred from bandwidth/compute, not measured.
- Hybrid numbers for Qwen3‑Coder‑Next‑80B‑A3B, Qwen3.5‑122B‑A10B, GLM‑4.7‑Flash on 16 GB + dual‑channel DDR4 were not found on GitHub; web search returned only low‑quality summaries (omitted). Use the §4 formula.
- I did not verify whether `--fit` gracefully falls back when it throws on user‑set `-ot` (it throws `common_params_fit_exception`; the caller likely logs and continues — pass `--fit off` when hand‑tuning to be safe).
- The NVIDIA FreeBSD driver's device‑local oversubscription behaviour (pageable memory) is driver‑side and not documented in llama.cpp.