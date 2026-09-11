Agent is idle (waiting for messages). agent_id: 3f11033c-8364-4c3e-9a69-e72a8902a7e9, agent_type: research, status: idle, description: Research non-Qwen coder models, elapsed: 1089s, total_turns: 1

[Turn 0]
Research complete. Here is the final report.

---

# Non-Qwen open-weight candidates for a llama.cpp/Vulkan coding-agent server (RTX 5000 16 GB + 128 GiB RAM), Sept 2026

## Summary

Of ~30 non-Qwen models checked at source (HF `config.json`, model-card READMEs, HF GGUF tree listings, llama.cpp master source + issue tracker), **four pass every hard requirement**: **NVIDIA Nemotron-3-Super-120B-A12B** (cleanest fit; mainline + MTP; SWE-bench Verified ≈ 60), its compressed sibling **Nemotron-Labs-3-Puzzle-75B-A9B** (only candidate whose experts fit at Q8_0 with margin; merged into llama.cpp 2026-09-03), **StepFun Step-3.5-Flash / Step-3.7-Flash** (best agentic scores: SWE-V 74.4, TB-2.0 51.0 / TB-2.1 59.5; but Q4-only for RAM, KV-heavy, and 256K is reached via llama3-type RoPE factor-2 scaling from 128K — a gray area against "no YaRN"), and **inclusionAI Ling-3.0-flash** (124B-A5B KDA+MLA hybrid, true 256K `rope_scaling: null`, tiny KV, but Q4-only for RAM, benchmarks are image-only, and its tool-call parser PR is still open). **Nemotron-3.5-Lightning-30B-A3B** passes too but is a weaker small model (SWE-V 51.6). Everything else fails: GLM-5.3-Flash, DeepSeek-V4-Flash/V4.1-Flash, MiniMax-M3, MiMo-V2.5, Kimi-K3, Hy4-preview, Hy3, LongCat, Ornith-1.5-397B (a Qwen3.5-397B fine-tune → out of scope) exceed 110 GiB of experts at ≤Q4; GLM-4.7-Flash, MiniMax-M2.1/M2.7, gpt-oss, Granite-4.2, ERNIE-4.5 fail native ctx; Devstral-2, Seed-OSS-36B, Command-A-Reasoning are dense and can't be split; Hunyuan-A13B fails VRAM on KV. Vulkan-specific caveats: Nemotron-H's Mamba-2 path and KDA/GDN kernels (Ling, GLM-5.3-Flash, Kimi-Linear) have open/closed Vulkan perf issues — see §5.

**Sizing conventions used** (all arithmetic shown per model): Q8_0 = 8.5 bpw (1.0625 B/param); Q4_K ≈ 4.5 bpw (0.5625 B/param); experts = n_moe_layers × n_experts × 3 × hidden × moe_intermediate (SwiGLU; Nemotron uses relu² → 2 matrices and a 1024-d latent); KV/token = 2 × n_full_attn_layers × n_kv_heads × head_dim × bytes (MLA: kv_lora_rank + qk_rope_head_dim, 1 "head"); q8_0 KV = 8.5/16 of f16; 110 GiB budget ⇒ ≤ ~111B expert params at Q8_0, ≤ ~210B at Q4_K.

---

## 1. Comparison table

| Model | Total/Active | Attn type | Native ctx | Thinking | KV @256K q8_0 (f16) | Non-expert GiB Q8 / Q4 | Expert GiB Q8 / Q4 | SWE-bench Verified | llama.cpp status | Verdict |
|---|---|---|---|---|---|---|---|---|---|---|
| **nvidia/Nemotron-3-Super-120B-A12B** | 120B / 12B | Hybrid: 40 Mamba2 + 40 LatentMoE + **8 GQA attn** (2 KV, hd 128) | 262,144 (card: 1M) | on/off (`enable_thinking`) | **1.06 GiB** (2.0) | ~7.2 / ~4.0 | **~111.5 / ~59** (real Q8_0 GGUF 119.65 GiB total; UD-Q6_K 106.9; UD-Q5_K_M 100.0) | 60.47 (OpenHands) / 59.20 (OpenCode) / 53.73 (Codex) | ✅ mainline `NEMOTRON_H_MOE` + MTP; open #28764 (MTP latent FFN), #27141 (ssm_scan assert) | **PASS** (Q6_K or lower for experts; Q8 experts ~1.5 GiB over budget) |
| **nvidia/Nemotron-Labs-3-Puzzle-75B-A9B** | 75B / 9.3B | Same 88-block hybrid, pruned experts (4–18 active), attention unchanged (8 attn, 2 KV, hd 128) | 262,144 (card: 1M) | on/off (default ON) | **1.06 GiB** (2.0) | ~7.2 / ~4.0 | **~67 / ~36** | 56.9 (OpenHands; parent 59.5 in same table) | ✅ PR #25444 **merged 2026-09-03** (`NemotronHPuzzle`); GGUF availability to verify | **PASS** (fits at Q8 with margin) |
| **nvidia/Nemotron-3.5-Lightning-30B-A3B** | 30B / 3B | Hybrid: 23 Mamba2 + 23 MoE + **6 attn** (2 KV, hd 128) | 262,144 (card: 1M) | on/off | 0.8 GiB (1.5) | ~2.3 / ~1.3 | ~29 / ~15.4 (official Q8_0 GGUF 31.28 GiB) | 51.56 | ✅ mainline; **official ggml-org GGUF** incl. MTP files | PASS (weak SWE-V) |
| **stepfun-ai/Step-3.5-Flash** (Feb 2026) | 196B / 11B | Hybrid: **12 full attn** (8 KV, hd 128) + 33 SWA-512 layers; 42 MoE layers | 262,144 via **llama3-type RoPE ×2 from 131,072** (not YaRN) | yes (thinking; 3.7 adds low/med/high) | **6.4 GiB** (12.0) | ~6.5 / ~3.7 | **~188 ✗ / ~99.6** (ggml-org Q4_K GGUF 110.56 GiB whole model; official IQ4_XS 104.99 GB) | **74.4**; TB-2.0 51.0; LCB-v6 86.4; τ²-Bench 88.2 | ✅ mainline `STEP35` (+3.7 mmproj); closed #22814 (tool-call leak), #24259 (reasoning loop) | **PASS\*** (Q4 experts only; VRAM tight: 3.7 + 6.4 + compute ≈ 11–12 GiB; RoPE-scaling gray area) |
| **stepfun-ai/Step-3.7-Flash** (May 2026) | 198B (196 LM + 1.8 vision) / 11B | same text stack | same | low/medium/high | 6.4 GiB (12.0) | ~6.5 / ~3.7 | same as 3.5 | SWE-Bench **PRO** 56.3; **TB-2.1 59.5**; Toolathlon 49.5 (no SWE-V in card) | ✅ mainline (`Step3p7ForConditionalGeneration`) | **PASS\*** (same caveats) |
| **inclusionAI/Ling-3.0-flash** (Aug 2026) | 124B / 5.1B | Hybrid: 35 KDA linear + **7 gated MLA** (kv_lora 512 + rope 64) | 262,144, `rope_scaling: null` | on by default (`enable_thinking`) | **1.05 GiB** (2.0) | ~3.2 / ~1.8 | **~120 ✗ / ~63** (bartowski Q8_0 126.3 GiB whole; Q6_K 101.8; Q4_K_M 72.5) | image-only (SWE-Bench Pro/Multilingual, TB-2.1 @256K) | ✅ mainline `BAILINGMOE3`; **open** PR #28682 (dedicated parser), **open** #27462 (tool_call terminator) | **PASS\*** (Q6/Q4 experts; parser pending; Vulkan GDN kernel perf) |
| zai-org/GLM-5.3-Flash | 320B / 18B | 34 KDA + 11 DSA-MLA, mHC | 1,048,576 | `reasoning_effort` low/high/max | ~1.2 GiB (MLA 11 layers) | ~9 / ~5 | ~323 ✗ / **~159 ✗** | not in text (approaches Opus 4.8 per card) | ❌ **not mainline**: open PRs #27754/#27773/#27917, issue #27922 | **FAIL (e) RAM, (d) mainline** |
| zai-org/GLM-4.7-Flash | 30B-A3B | full MLA (Glm4MoeLite) | **202,752** | yes | — | — | — | — | ✅ (as DEEPSEEK2) | **FAIL (b)** |
| deepseek-ai/DeepSeek-V4-Flash-0731 | ~284B / ~13B | MLA-like hd 512, 1 KV head, compressed 4/128 + DSA | 1M via **YaRN ×16 from 65,536** | `reasoning_effort` low/high/max | small (MLA) | ~7 / ~4 | ~277B params → **~145 GiB ✗ @Q4** | TB-2.1 82.7, DeepSWE 54.4, Toolathlon 70.3 (no SWE-V) | ✅ `DEEPSEEK4`; **open** #26685 Vulkan RPC garbled | **FAIL (e) RAM + (b) YaRN** |
| deepseek-ai/DeepSeek-V4.1-Flash (Sep 10 2026) | larger (384 experts, hidden 5120, moe_int 2304, 40 layers) | as V4 + engram | YaRN ×16 | yes | — | — | ~544B params ✗ | — | ❌ no `deepseek_v41` converter | **FAIL (e), (d), (b)** |
| tencent/Hy4-preview (Aug 27 2026) | 256 experts × 78 layers × 6144 × 2048 → ~750B ✗ | DSA-MLA (kv_lora 512) | 1,048,576 | ? | — | — | ✗ | — | ✅ PR #28127 merged 2026-09-04 | **FAIL (e)** |
| tencent/Hy3 | 79 MoE layers × 192 × 4096 × 1536 → ~286B | GQA 80 layers × 8 KV × 128 | 262,144 | ? | **~17 GiB q8** ✗ | — | ~150 GiB ✗ @Q4 | — | ✅ `HY_V3` | **FAIL (e)** |
| tencent/Hunyuan-A13B | 80B/13B | GQA 32×8×128 | 256K via NTK | yes | ~17 GiB ✗ | — | — | — | ✅ | **FAIL (e) VRAM** |
| MiniMaxAI/MiniMax-M2.1 / M2.7 | 230B/10B | full attn | **196,608 / 204,800** | yes | — | — | — | 74.0 (M2.1) | ✅ | **FAIL (b)** |
| MiniMaxAI/MiniMax-M3 | ~430B (60 × 128 × 6144 × 3072) | sparse attn | 1M | yes | — | — | ~413B ✗ | — | ✅ `MINIMAX_M3` | **FAIL (e)** |
| XiaomiMiMo/MiMo-V2-Flash / V2.5 / V2.5-Pro | 309B / ~310B / larger | hybrid SWA | 256K / 1M | yes | — | — | ~303B ✗ | 73.4 (V2-Flash) | ✅ `MIMO2` | **FAIL (e)** |
| moonshotai/Kimi-K3 (Jun 2026) | 93 layers × 896 experts × 7168 × 3072 → multi-T | 24 full MLA + KDA | 1M | yes | — | — | ✗✗ | — | ✅ `KIMI_K3` | **FAIL (e)** |
| moonshotai/Kimi-Linear-48B-A3B-Instruct | 48B/3B | 7 MLA + 20 KDA | 1M | **no thinking mode found in card** | small | — | ~47B → ~26 GiB Q4 | none published (research model) | ✅ `KIMI_LINEAR` | **FAIL (a)/(c)** |
| Kimi-K2.5 / K2.6 / K2.7-Code | 1T | MLA | 256K | yes | — | — | ✗ | — | ✅ | **FAIL (e)** |
| ornith-ai/Ornith-1.5-397B(-FP8/GGUF) | 397B/17B (`Qwen3_5MoeForConditionalGeneration`) | Qwen3.5 GDN hybrid | 262,144 | yes | — | — | ~386B → ~203 GiB Q4 ✗ | — | ✅ (Qwen3.5 arch) | **FAIL (e); Qwen-derivative (out of scope)** |
| Kwaipilot/KAT-Coder-V2.5-Dev | Qwen3.5-35B-A3B fine-tune (`qwen3_5_moe`) | — | 262,144 | yes | — | — | — | — | ✅ | Qwen-derivative (out of scope); KAT-Dev-72B dense FAIL |
| mistralai/Devstral-2-123B / Devstral-Small-2-24B | dense 123B / 24B | full | 256K | no native thinking | — | — | — | 72.2 / 68.0 | ✅ | **FAIL (e) dense, (a)** |
| ByteDance-Seed/Seed-OSS-36B-Instruct | dense 36B | GQA | 512K | thinking budget | — | — | — | — | ✅ `SEED_OSS` | **FAIL (e) dense** |
| ibm-granite/granite-4.2-30b | dense 30B | full | **131,072** | yes | — | — | — | — | ✅ | **FAIL (b), (e)** |
| openai/gpt-oss-120b / 20b | 117B/5B, 21B/3.6B | SWA/full alternating | **131,072** | reasoning_effort | — | — | — | — | ✅ | **FAIL (b)** |
| baidu/ERNIE-4.5-21B-A3B-Thinking | 21B/3B | full | **131,072** | yes | — | — | — | — | ✅ | **FAIL (b)** |
| meituan-longcat/LongCat-Flash-Lite-Sparse / LongCat-2.0 | 14-layer MLA/LSA, YaRN ×120 / ~1.5T | — | YaRN | yes | — | — | ✗ | — | ❌ no arch | **FAIL (b)/(d)/(e)** |
| CohereLabs/command-a-reasoning-08-2025 | dense 111B, CC-BY-NC | — | 256K | yes | — | — | — | — | ✅ | **FAIL (e) dense, license** |

\* = passes, with caveats detailed below.

---

## 2. Per-model notes (viable candidates)

### 2.1 nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-BF16 — https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-BF16
- **config.json**: `NemotronHForCausalLM`, 88 layers, `hybrid_override_pattern` = 40 M(amba2) + 40 E(MoE) + 8 *(attention); hidden 4096; `n_routed_experts` 512, top-22, `moe_intermediate_size` 2688, **`moe_latent_size` 1024** (LatentMoE), relu² MLP (2 matrices), shared expert 5376; attn 32 heads / **2 KV heads / head_dim 128**; **`max_position_embeddings` 262144** (card: up to 1M, RULER@1M 91.75); `num_nextn_predict_layers` 1 (MTP); vocab 131072. License: NVIDIA Open Model License.
- **KV**: 8 attn layers × 2 (K,V) × 2 KV heads × 128 × 2 B = **8,192 B/tok** f16 → ×262,144 = 2.0 GiB f16, **~1.06 GiB q8_0**. Mamba2 recurrent state ≈ 168 MB (fixed).
- **Experts**: 40 × 512 × 2 × 1024 × 2688 ≈ 112.7B params → Q8_0 ≈ 119.7 GB = **111.5 GiB (≈1.5 GiB over budget)**; Q6_K ≈ 86 GiB; Q4_K ≈ 59 GiB. **Cross-check** (HF tree API, `unsloth/NVIDIA-Nemotron-3-Super-120B-A12B-GGUF`): Q8_0 = 119.65 GiB total, UD-Q6_K = 106.87, UD-Q5_K_M = 99.96, UD-Q4_K_M = 76.87, UD-IQ4_XS = 60.06 GiB (whole model) → consistent. Non-expert ≈ 7.3B → ~7.2 GiB Q8 / ~4 GiB Q4. **VRAM plan**: non-expert Q8 (7.2) + KV q8 (1.06) + SSM (0.17) ≈ 8.5 GiB → fits 14 GiB with room for compute buffers.
- **Card benchmarks**: SWE-Bench Verified (OpenHands) **60.47** / OpenCode 59.20 / Codex 53.73; LiveCodeBench v5 81.19; Terminal Bench Core 2.0 31.00; TauBench V2 avg 61.15. (Lightning card re-evaluates Super with NVIDIA harness: SWE-V 63.08, TB-2.1 39.61.) Reasoning on/off via `enable_thinking`; `--reasoning-parser nemotron_v3`.
- **llama.cpp**: arch `NEMOTRON_H_MOE` in `src/llama-arch.h`; converter `conversion/nemotron.py:198-363` (handles `moe_latent_size` at :360 and MTP export). Issues: #20466/#20732/#22346 closed; **#23348 (closed 2026-05-26) "Nemotron 3 Super consuming 100% CPU on Vulkan"** (AMD iGPU; slow vs GLM-4.5-Air) — Mamba2/SSM ops may fall back to CPU on Vulkan, verify with `GGML_VULKAN` build; **#27141 open** (`nemotron_h_moe` aborts in `ggml_ssm_scan` during context reservation, Metal, Nano-Omni); **#28764 open PR** "nemotron-h, create the MTP latent FFN projection for the NextN layer"; **#28617 PR closed NOT merged** (MTPv2 draft head for Super) → MTP speculative decoding for Super may still be imperfect. GGUFs: unsloth, bartowski, lmstudio-community, AesSedai.

### 2.2 nvidia/NVIDIA-Nemotron-Labs-3-Puzzle-75B-A9B-BF16 (Jun 24 2026, OpenMDW-1.1) — https://huggingface.co/nvidia/NVIDIA-Nemotron-Labs-3-Puzzle-75B-A9B-BF16
- **config.json**: `NemotronHPuzzleForCausalLM`/`nemotron_h_puzzle`, 88 `block_configs`, hidden 4096, 512 experts, `moe_latent_size` 1024, shared 5376, 32 heads / **2 KV / hd 128**, **262144** ctx (card: 1M), MTP 1, vocab 131072. Card: **75B total / 9.3B active**; active experts pruned from 22 to 4–18 per layer; smaller Mamba state; "Attention layers are left unchanged".
- **KV**: identical to Super → **1.06 GiB q8_0 @256K**.
- **Experts**: ≈ 75B − ~7.3B non-expert ≈ 67.7B → **Q8_0 ≈ 67 GiB, Q4_K ≈ 36 GiB** — the only ≥50B-class candidate whose experts fit at Q8_0 with headroom (~43 GiB spare).
- **Card benchmarks** (Puzzle vs parent Super in same table): LiveCodeBench v5 81.1 (82.1), Terminal Bench hard 24.0 (25.5), **SWE-Bench (OpenHands) 56.9 (59.5)**, TauBench V2 listed. Reasoning ON default; `--reasoning-parser nemotron_v3`. SWE-RL post-training pipeline.
- **llama.cpp**: PR **#25444 merged 2026-09-03** ("model: add NVIDIA Nemotron-3-Puzzle-75B-A9B (NemotronHPuzzle) support"). GGUF repos not yet enumerated (search `Puzzle-75B GGUF` on HF; unsloth/bartowski likely by now) — **verify before relying**.

### 2.3 nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-BF16 (Aug 2026, OpenMDW-1.1) — https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-BF16
- 52 layers (23 Mamba2 / 23 MoE / **6 attn**, 2 KV, hd 128), hidden 2688, 128 experts top-6, moe_int 1856, shared 3712, ctx 262144 (card 1M), MTP 1. KV = 6×2×2×128×2 = 6,144 B/tok → 1.5 GiB f16 / **0.8 GiB q8_0**. Experts ≈ 29.4B → ~29 GiB Q8 / ~15 GiB Q4. **Official GGUF**: `ggml-org/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-GGUF` — Q8_0 31.28 GiB, Q4_0 17.60 GiB, BF16 58.84, plus `mtp-*.gguf` draft files (2.03 GiB Q8_0). Card: **SWE-bench Verified 51.56**, SWE-bench Multilingual 39.33, Terminal-Bench 2.1 24.58, PinchBench 85.37. Whole model at Q8 nearly fits in VRAM+RAM trivially; the weakest coder of the passing set.
- No "Nemotron-3.5-Super" exists as of 2026-09-11 (HF `author=nvidia&search=Nemotron-3.5` lists only Lightning-30B variants, Content-Safety, ASR).

### 2.4 stepfun-ai/Step-3.5-Flash (Feb 2026) and Step-3.7-Flash (May 23 2026), Apache-2.0 — https://huggingface.co/stepfun-ai/Step-3.5-Flash , https://huggingface.co/stepfun-ai/Step-3.7-Flash
- **config.json**: 45 layers, layers 3–44 MoE (42), 288 experts top-8, `moe_intermediate_size` 1280, shared 1280, dense layers 0–2 (intermediate 11264), hidden 4096; `layer_types` [full, sliding×3] → **12 full-attention layers (64 heads / 8 KV / hd 128)** + 33 sliding (window 512, 96 heads / 8 KV / 128); **`max_position_embeddings` 262144 but `rope_scaling` = `{type: llama3, factor 2.0, original_max_position_embeddings 131072}`, `yarn_only_types: ["full_attention"]`**; `num_nextn_predict_layers` 3 (MTP-3); vocab 128896. Card: 196.81B total (196B backbone + 0.81B head), ~11B active, "256K context window".
- **Gray area on (b)**: 256K is achieved by llama3-style RoPE frequency scaling (×2 from a 128K pretraining base) — technically "not YaRN", but it *is* a scaled context; treat as conditional pass. Card states 3:1 SWA ratio was designed for 256K.
- **KV**: 12 × 2 × 8 × 128 × 2 = **49,152 B/tok** f16 → 12.0 GiB f16 @256K, **~6.4 GiB q8_0**; SWA layers with SWA cache ≈ 69 MB. Non-expert ≈ 6.6B → ~6.5 GiB Q8 / ~3.7 GiB Q4. **VRAM plan**: non-expert **Q4** (3.7) + KV **q8_0** (6.4) ≈ 10.1 GiB + compute → fits 14 GiB; Q8 non-expert (6.5 + 6.4 = 12.9) is too tight with Vulkan compute buffers.
- **Experts**: 42 × 288 × 3 × 4096 × 1280 ≈ 190.2B → **Q8_0 ≈ 188 GiB FAIL**, Q4_K ≈ 99.6 GiB OK, IQ4_XS ≈ 94 GiB. **Cross-check**: `ggml-org/Step-3.5-Flash-GGUF/Step-3.5-Flash-Q4_K.gguf` = **110.56 GiB** whole model; card §6.4: Q4_K_S 111.5 GB, IQ4_XS 104.99 GB, Q3_K_L 102.5 GB → experts ≈ 106 GiB at Q4_K (offload non-expert to GPU; RAM budget ~104–106 GiB → **tight but within 110**). Prefer IQ4_XS/UD-Q4_K_S for margin.
- **Card benchmarks (Step-3.5-Flash README table)**: **SWE-bench Verified 74.4**, Terminal-Bench 2.0 **51.0**, LiveCodeBench-V6 86.4, τ²-Bench 88.2, BrowseComp 69.0. **Step-3.7-Flash**: SWE-Bench PRO 56.3, Terminal-Bench 2.1 **59.5**, Toolathlon 49.5, ClawEval-1.1 67.1; reasoning effort low/medium/high; +1.8B vision encoder (mmproj).
- **llama.cpp**: `STEP35` arch; `conversion/step3.py:100` registers `Step3p5ForCausalLM` and `Step3p7ForConditionalGeneration` (mmproj at :18; llama3 rope at :288-295). #19311 (feature request) closed; **#22814 closed 2026-06-21** "tool call syntax leaking into Response content – Step-3.5-Flash-Q8"; **#24259 closed 2026-08-15** "infinite `<<<<` in Step 3.7 flash reasoning"; #20515 closed (AMD Vulkan DeviceLost). Card's llama.cpp section still points to the stepfun fork branch `step3.7`, but mainline has both. GGUFs: `stepfun-ai/Step-3.5-Flash-GGUF-Q4_K_S`/`-Q8_0`, `ggml-org/Step-3.5-Flash-GGUF`, `stepfun-ai/Step-3.7-Flash-GGUF`, bartowski, ubergarm (ik_llama).

### 2.5 inclusionAI/Ling-3.0-flash (Aug 2026, MIT) — https://huggingface.co/inclusionAI/Ling-3.0-flash
- **config.json**: `BailingMoeV3ForCausalLM` / `bailing_hybrid`; 42 layers = **35 KDA + 7 gated MLA** (`layer_group_size` 6); first 2 dense (6144); 512 experts top-8, `moe_intermediate_size` 768, shared 768; hidden 2560; 32 heads; MLA `kv_lora_rank` 512, `qk_rope_head_dim` 64, `qk_nope` 128, `v_head` 128; **`max_position_embeddings` 262144, `rope_scaling: null`** (card: trained 8K→32K→256K); MTP 1; vocab 157184; `no_kda_lora` true. Card: **124B total / 5.1B active**, "native hybrid reasoning", thinking on by default (`enable_thinking` toggle).
- **KV** (MLA, 7 layers): 7 × (512 + 64) × 2 B = **8,064 B/tok** f16 → 2.0 GiB f16, **~1.05 GiB q8_0** @256K (plus KDA recurrent state, small).
- **Experts**: 40 × 512 × 3 × 2560 × 768 ≈ 120.8B → **Q8_0 ≈ 120 GiB FAIL**, Q6_K ≈ 94 GiB, Q4_K ≈ 63 GiB. **Cross-check** (`bartowski/Ling-3.0-flash-GGUF`): Q8_0 126.32 GiB, Q6_K 101.76, Q4_K_M 72.46 whole model → consistent. Non-expert ≈ 3B → ~3.2 GiB Q8 / ~1.8 Q4 → VRAM ≈ 4.3 GiB total: **most VRAM-frugal candidate**.
- **Benchmarks**: card publishes SWE-Bench Pro / SWE-bench Multilingual / Terminal-Bench 2.1 (evaluated at 256K ctx) **only as images** → numbers not extractable here; no SWE-bench Verified text figure.
- **Caveat**: SGLang recipe in card mentions "256K YaRN context" despite `rope_scaling: null` — wording conflict; config is authoritative but flag it.
- **llama.cpp**: `BAILINGMOE3` arch (`conversion/bailingmoe3.py:15-62`); #26590 (model request) closed 2026-08-17; #27288 (OOM loading) closed; **open #27462** "Bailing V3 (Ling 3.0) autoparser lacks a `<tool_call>` reasoning terminator"; **open PR #28682** "chat: add dedicated Ling 3.0 (Bailing V3) parser" → tool-calling in reasoning mode is not yet clean on mainline. Vulkan: KDA uses GATED_DELTA_NET ops — see §5. GGUFs: AtomicChat/Ling-3.0-flash-GGUF (296K dl), bartowski, bloomer010 (+REAP prunes).

---

## 3. Failing models — reasons (with source values)

- **zai-org/GLM-5.3-Flash** (Aug 25 2026, MIT) — https://huggingface.co/zai-org/GLM-5.3-Flash — config: `Glm5NextForConditionalGeneration`, 45 layers (34 KDA + 11 DSA-MLA, mHC), 288 experts top-8, moe_int 2048, hidden 4096, first 3 dense, ctx 1,048,576, kv_lora 512, MTP 1; card: 320B/18B, `reasoning_effort` low/high/max, "approaching Claude Opus 4.8 on coding and agentic benchmarks" (TB-2.1 in Claude Code, DeepSWE, Toolathlon; numeric table not in plain text). Experts ≈ 42 × 288 × 3 × 4096 × 2048 ≈ 304B → Q4 ≈ 159 GiB **FAIL RAM** (would need ≤2.9 bpw). **Not in mainline** llama.cpp: open PRs #27754 ("model: add GLM-5-Next (GLM-5.3-Flash)"), #27773, #27917 (MTP), issue #27922; `unsloth/GLM-5.3-Flash-GGUF` (337K dl) requires PR builds. **FAIL (d),(e)**.
- **GLM-4.7-Flash**: `max_position_embeddings` 202,752 → **FAIL (b)**.
- **DeepSeek-V4-Flash-0731** (Jul 31 2026, MIT) — https://huggingface.co/deepseek-ai/DeepSeek-V4-Flash-0731 — 43 layers, 256 experts top-6, moe_int 2048, hidden 4096, `rope_scaling` **yarn factor 16 from 65,536**, expert_dtype fp4; card table: TB-2.1 82.7, NL2Repo 54.2, DeepSWE 54.4, Toolathlon-Verified 70.3 (no SWE-V); `reasoning_effort` low/high/max, recommends 384K output. Experts ≈ 277B → Q4 ≈ 145 GiB **FAIL (e)**; YaRN-trained **FAIL/gray (b)**. llama.cpp `DEEPSEEK4` supported; **open #26685** "DeepSeek V4 garbled output with RPC Vulkan" (updated 2026-09-09).
- **DeepSeek-V4.1-Flash** (Sep 10 2026): `deepseek_v41`, 40 layers, hidden 5120, 384 experts, moe_int 2304 → ~544B expert params **FAIL (e)**; no mainline converter **FAIL (d)**; YaRN ×16.
- **tencent/Hy4-preview** (Aug 27 2026): `HYV4ForCausalLM`, 78 layers, hidden 6144, 256 experts top-8, moe_int 2048, DSA-MLA, ctx 1M, MTP 1 → ≈750B expert params **FAIL (e)** (llama.cpp PR #28127 merged 2026-09-04; open #28722 WebGPU crash). **tencent/Hy3**: 80 layers, hidden 4096, 192 experts, moe_int 1536, ctx 262144, GQA 8 KV × hd 128 × 80 layers → KV q8 ≈ 17 GiB and experts ≈ 286B → **FAIL (e)**.
- **Hunyuan-A13B**: 32 GQA layers × 8 KV × 128 → 131 KB/tok → **17 GiB q8 @256K FAIL (e)**; 256K via NTK scaling.
- **MiniMax-M2.1 (196,608) / M2.7 (204,800)** → **FAIL (b)**; **MiniMax-M3**: 60 × 128 × 3 × 6144 × 3072 ≈ 413B experts **FAIL (e)**.
- **MiMo-V2-Flash 309B / MiMo-V2.5 (48 × 256 × 4096 × 2048 ≈ 303B) / V2.5-Pro (70 layers)** → **FAIL (e)**.
- **Kimi-K3**: config 93 layers, hidden 7168, 896 experts, moe_int 3072, 24 full-attn MLA layers, ctx 1M → multi-trillion **FAIL (e)**. **Kimi-K2.5/2.6/2.7-Code** 1T **FAIL (e)**. **Kimi-Linear-48B-A3B-Instruct**: 1M ctx, KIMI_LINEAR supported, experts ≈ 47B fit — but card is a research release with no thinking toggle and no coding-agent benchmarks → **FAIL (a)/(c)**.
- **Ornith-1.5-397B** — publisher **ornith-ai** (HF org; also 1.0-397B Jun 2026, 1.5-35B-A3B, 1.5-9B, all `qwen3_5_moe`/`qwen3_5`): `Qwen3_5MoeForConditionalGeneration`, 60 layers, 512 experts, moe_int 1024, ctx 262144 → **confirmed Qwen3.5-397B-A17B fine-tune**; experts ≈ 386B → ~203 GiB Q4 **FAIL (e)**; out of this thread's scope. Ornith-1.5-35B-A3B(-GGUF) is a Qwen3.5-35B-A3B derivative (for the Qwen thread).
- **Kwaipilot/KAT-Coder-V2.5-Dev** (Jul 2026): `qwen3_5_moe`, hidden 2048, 40 layers, 256 experts, moe_int 512 → Qwen3.5-35B-A3B fine-tune (Qwen thread). KAT-Dev-72B-Exp dense **FAIL (e)**.
- **Devstral-2-123B / Devstral-Small-2-24B**: dense (no expert/attention split possible), no native reasoning → **FAIL (e),(a)**. **Seed-OSS-36B** dense (512K, thinking budget) → **FAIL (e)** (36B Q4 ≈ 20 GiB > 14 GiB VRAM; running dense from RAM at 40 GB/s ≈ 2 tok/s). **granite-4.2-30b**: dense, 131,072 → **FAIL (b),(e)**. **gpt-oss-120b/20b**: 131,072 → **FAIL (b)**. **ERNIE-4.5-21B-A3B-Thinking**: 131,072 → **FAIL (b)**; no ERNIE-5 open weights. **LongCat-Flash-Lite-Sparse**: YaRN ×120 from 8192, no llama.cpp arch → **FAIL (b),(d)**; LongCat-2.0 ~1.5T **FAIL (e)**. **Command-A-Reasoning-08-2025**: dense 111B, CC-BY-NC → **FAIL (e)**; command-a-plus-05-2026 (Apache-2.0, `cohere2_vision`) not sized — likely dense.

---

## 4. Recommendation ranking (for this hardware)

1. **Nemotron-3-Super-120B-A12B** at UD-Q5_K_M/Q6_K (experts ~93–100 GiB RAM) with non-expert Q8 + KV q8_0 (~8.5 GiB VRAM) — mainline, MTP, clean 262K config, 2-KV-head attention makes 256K KV trivial; SWE-V ≈ 60 is the weak spot; watch Vulkan SSM performance (#23348) and #27141/#28764.
2. **Step-3.7-Flash / Step-3.5-Flash** at IQ4_XS/Q4_K_S (experts ~94–106 GiB) with non-expert Q4 + KV q8_0 (~10 GiB VRAM) — by far the strongest agentic numbers (SWE-V 74.4, TB-2.1 59.5), MTP-3, mainline; caveats: RoPE ×2 scaling to 256K, KV 6.4 GiB, RAM budget nearly maxed, no Q8 option.
3. **Ling-3.0-flash** at Q6_K/Q4_K_M (experts ~63–94 GiB) — most VRAM-frugal (≈4.3 GiB), true `rope_scaling: null` 256K; blocked on the tool-call parser PR (#28682) and Vulkan GDN kernel maturity; benchmarks not machine-readable.
4. **Nemotron-Labs-3-Puzzle-75B-A9B** at Q8_0 (experts ~67 GiB) — fits at Q8 with headroom, same KV as Super, merged 2026-09-03; ~3 pts below Super on SWE-Bench; check GGUF availability.
5. **Nemotron-3.5-Lightning-30B-A3B** — fast, official ggml-org GGUF with MTP, but SWE-V 51.6.

---

## 5. llama.cpp / Vulkan status references

- Arch list (master): https://raw.githubusercontent.com/ggml-org/llama.cpp/master/src/llama-arch.h — includes `STEP35`, `NEMOTRON_H_MOE`, `BAILINGMOE3`, `DEEPSEEK4`, `KIMI_LINEAR`, `KIMI_K3`, `MIMO2`, `MINIMAX_M2/M3`, `HY_V3/HY_V4`, `SEED_OSS`, `HUNYUAN_MOE`, `ERNIE4_5_MOE`, `GRANITE_HYBRID`, `GLM_DSA` (dense GLM-5.x, **not** Flash); **no `GLM5_NEXT`, no `deepseek_v41`**. Converters live in `conversion/*.py` (`convert_hf_to_gguf.py` is now a shim).
- Vulkan-relevant: **#20377 open PR** "vulkan: chunked parallel kernel for GATED_DELTA_NET" (KDA/GDN models: Ling-3.0, Kimi-Linear, GLM-5.3-Flash); #27998 closed "Vulkan GATED_DELTA_NET pipeline compile hangs on gfx1103"; **#27638 open** "[Vulkan/ANV] Flash Attention fallback to SCALAR path"; **#27332 open PR** "vulkan: use density gate for MUL_MAT_VEC_ID path" (MoE expert matvec perf); #22675 closed "CUDA chunked SSD matmul for Mamba-2 prefill" (CUDA only — Vulkan Mamba-2 prefill likely slower); **#23348 closed** "Nemotron 3 Super consuming 100% CPU on Vulkan"; **#26685 open** "DeepSeek V4 garbled output with RPC Vulkan".
- Tool-calling / reasoning format: Step — #22814 closed (tool-call leak), #24259 closed (reasoning loop); Ling — #27462 open, PR #28682 open; Nemotron — `--reasoning-parser nemotron_v3` per card; PR #28617 (Super MTPv2 draft head) closed **unmerged**; #28764 open (MTP latent FFN projection).

## 6. Gaps and uncertainties

- Ling-3.0-flash and GLM-5.3-Flash coding numbers are image-only / not in text — SWE-V column left blank; Step-3.7's card gives SWE-Bench **Pro** (56.3) not Verified.
- Step-3.5/3.7's 256K depends on llama3-type RoPE ×2 scaling (`original_max_position_embeddings` 131072) — whether this violates "without YaRN" is a judgment call for the main agent.
- Expert/non-expert splits are architectural estimates (±5%); whole-model GGUF totals were cross-checked (Nemotron Super, Lightning, Step-3.5, Ling-3.0) and agree.
- Nemotron-Puzzle-75B GGUF repos and Vulkan behaviour not verified; NemotronHPuzzle support is 8 days old.
- Kimi-K3 exact expert count/active params not parsed beyond the config fields shown (`num_experts` 896, hidden 7168, moe_int 3072, 93 layers) — clearly out of budget regardless.
- Command-A-Plus-05-2026 and MiMo-V2.5-Pro configs were not fully sized (both clearly outside budget or dense).
- GitHub `search_code` returned 0 results throughout (index limitation); llama.cpp verification used raw master files + the issues/pulls REST API instead.