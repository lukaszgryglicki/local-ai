## Report: Chinese-lab open-weight *thinking* LLMs ≤ ~50B for the RTX 5000 16 GiB / llama.cpp-Vulkan box (as of 2026-09-11)

**Method (all numbers fetched, none from memory).** Configs: `https://huggingface.co/<repo>/raw/main/config.json`; params/dates: `https://huggingface.co/api/models/<repo>` (`safetensors.total`, `createdAt`); GGUF sizes: `https://huggingface.co/api/models/<gguf-repo>/tree/main?recursive=true` (single-file quants throughout; multipart not needed) and per-tensor expert/non-expert byte splits parsed from the GGUF headers (Range-fetched). llama.cpp support: master `src/llama-arch.cpp` (https://github.com/ggml-org/llama.cpp/blob/master/src/llama-arch.cpp) + `conversion/__init__.py` registry (https://github.com/ggml-org/llama.cpp/blob/master/conversion/__init__.py). KV rules verified in source: MLA models allocate **K only** (`has_v = !is_mla`, `src/llama-kv-cache.cpp` L231-244) so MLA = (kv_lora_rank+rope_dim)=576 elems/token/layer; recurrent state `n_embd_s = head_dim²×n_head` (GDN/KDA) / `ssm_d_state×ssm_d_inner`, conv `n_embd_r = (d_conv−1)×(d_inner+2·n_group·d_state)` (`src/llama-hparams.cpp` L208-257). Tied-embedding models: loader re-loads `token_embd` as the output tensor (`src/llama-model-loader.cpp` L1154-1160), so for tied models I count `token_embd` in VRAM (conservative). Budget: weights(resident) + KV q8_0@262,144 (1.0625 B/elem) + recurrent + 1.2 ≤ 15.5 GiB. Speed = user's model (300 GB/s GPU + 2 ms; 30 GB/s CPU + 0.2 ms/offloaded layer); 1 GiB = 1.0737 GB.

---

### 1. Ranked master table (pass (a)+(d)); tier, then expected tg

| # | model (HF) | params | arch summary (from config.json/GGUF header) | native ctx | thinking | llama.cpp | GGUF: repo, best quant, GiB | KV q8 @262K | VRAM used | tier | exp. tg | SWE-V / LCB-v6 / TB | risks |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | tencent/Hunyuan-0.5B-Instruct (2025-07-30, 0.54B) | 0.54B dense | 24 L, all full-attn, 8 kv×128, tied emb | 262,144 (dynamic-NTK α=1000, factor 1) | default slow-thinking; `enable_thinking=False` or `/no_think` | `hunyuan-dense` (PR #14878) | bartowski/tencent_Hunyuan-0.5B-Instruct-GGUF Q8_0 **0.538** (bf16 1.009 also fits) | 24×2048 el×1.0625 B×262,144 = 13.69 GB = **12.75 GiB** | 0.53+12.75+1.2 = **14.48** (bf16: 14.96) | **T0** | 0.534 GiB→1.9+2 ms ≈ **256 t/s** | – / LCB 11.1 (old LCB) / – ; BFCL-v3 49.8, τ-Bench 14.4 | Very weak coder; KV dwarfs weights; MHA-ish KV |
| 2 | Qwen/Qwen3.5-0.8B (2026-02-28, 0.87B) | 0.87B dense hybrid | 24 L: 18 GDN + 6 full (interval 4), 2 kv×256, tied; GDN 16 v-heads×128×128 | 262,144 | default thinking; `enable_thinking:false` | `qwen35` (PR #19468) | unsloth/Qwen3.5-0.8B-GGUF Q8_0 **0.756** (BF16 1.413 fits) | 6×1024×1.0625×262,144 = 1.71 GB = **1.59 GiB** | 0.76+1.59+0.02+1.2 = **3.57** | **T0** | ≈ **212 t/s** | – / – / – ; BFCL-V4 25.3, TAU2 11.6 | No coding numbers; toy-class |
| 3 | Kwaipilot/KAT-Coder-V2.5-Dev (2026-07-23, 34.66B, base Qwen3.6-35B-A3B) | 34.7B / ~3B act MoE | 40 L: 30 GDN + 10 full, 2 kv×256; 256 exp top-8, moe_int 512 (k-quant OK), shared 512 | 262,144 | thinks by default; `enable_thinking=false`, `preserve_thinking` | `qwen35moe` | bartowski/Kwaipilot_KAT-Coder-V2.5-Dev-GGUF **IQ2_M 11.238** (experts 9.855 = IQ2_S 8.89+IQ3_S 0.97; other 0.843, out 0.326, tok 0.204→CPU) | 10×1024×1.0625×262,144 = 2.85 GB = **2.66 GiB** | 11.02+2.66+0.06+1.2 = **14.94** | **T0** (IQ2_M); T2 for IQ3_XXS…Q6_K (see §2) | (1.169+9.855×8/256) GiB = 1.586 GB → 5.3+2 ms ≈ **137 t/s** | **SWE-V 69.40** / – / **TB-2.1 41.02**; SWE-Multilingual 63.0, SWE-Pro 45.96 | Only 2-bit fits all-in-VRAM; Vulkan GDN issues (§3) |
| 4 | Qwen/Qwen3.5-35B-A3B (2026-02-24, 35.95B) | 34.7B/3B MoE | same as #3 | 262,144 | default thinking | `qwen35moe` | unsloth/Qwen3.5-35B-A3B-GGUF **UD-IQ2_M 10.609** (experts 8.984 = IQ2_XXS 5.16+IQ3_XXS 3.83; other 1.023, out 0.266) | **2.66 GiB** | 10.27+2.66+0.06+1.2 = **14.19** | **T0** (UD-IQ2_M); **T1(ii)** UD-IQ3_XXS 12.18 GiB with k=1 (1.05×, 15.44 GiB) | ≈ **131 t/s** (UD-IQ3_XXS k=1: 109) | **69.2 / 74.6 / TB-2 40.5**, CodeForces 2028, OJBench 36.0 | 2-bit; same Vulkan GDN risk |
| 5 | tencent/Hunyuan-1.8B-Instruct (2025-07-30, 1.79B) | 1.8B dense | 32 L full-attn, 4 kv×128, tied | 262,144 | as #1 | `hunyuan-dense` | bartowski/tencent_Hunyuan-1.8B-Instruct-GGUF Q8_0 **1.777** (bf16 3.341 fits) | 32×1024×1.0625×262,144 = 9.13 GB = **8.50 GiB** | 1.77+8.50+1.2 = **11.47** (bf16 13.04) | **T0** | ≈ **120 t/s** | – / LCB 31.5 (old) / – ; BFCL-v3 58.3, τ-Bench 18.2 | Weak coder; 2025-era |
| 6 | Qwen/Qwen3.5-2B (2026-02-28, 2.27B) | 2.3B dense hybrid | 24 L: 18 GDN + 6 full, 2 kv×256, tied; GDN 16×128×128 | 262,144 | default thinking | `qwen35` | unsloth/Qwen3.5-2B-GGUF Q8_0 **1.874** (BF16 3.516 fits) | **1.59 GiB** | 1.87+1.59+0.02+1.2 = **4.69** | **T0** | ≈ **115 t/s** | 5.0 / 20.2 / 3.0 (3rd-party, MiniCPM5-2B card); own: BFCL-V4 43.6, TAU2 48.8 | Weak agentic coder |
| 7 | Qwen/Qwen3.5-4B (2026-02-27, 4.66B) | 4.7B dense hybrid | 32 L: 24 GDN + 8 full, 4 kv×256, tied (tok 0.629 GiB counted); GDN 32×128×128 | 262,144 | default thinking | `qwen35` | unsloth/Qwen3.5-4B-GGUF Q8_0 **4.175** (BF16 7.846 fits: 13.34 GiB) | 8×2048×1.0625×262,144 = 4.56 GB = **4.25 GiB** | 4.16+4.25+0.05+1.2 = **9.66** | **T0** | 4.164 GiB→14.9+2 ≈ **59 t/s** (BF16 ≈33) | 33.6 (3rd-party) / **55.8** own (56.4 3rd-party) / TB-2.1 25.8 (two 3rd-party sources agree); BFCL-V4 50.3, TAU2 79.9 | Best small T0 coder; Vulkan GDN |
| 8 | inclusionAI/Ling-3.0-tiny (2026-08-10, 7.89B) | 7.9B / 1.3B act MoE hybrid | 24 L: 18 KDA + 6 MLA (kv_lora 512+rope 64), first_k_dense 1; 128 exp top-8, moe_int 512, 1 shared | 131,072 (official 256K recipe = YaRN factor 2.0) | thinking default; `enable_thinking` per request | `bailingmoe3` (PR #26608 merged 2026-08-17) | inclusionAI/Ling-3.0-tiny-GGUF (official) **Q8_0 7.825** (experts 6.873, other 0.474, out 0.239, tok 0.239→CPU) | 6×576×1.0625×262,144 = 0.96 GB = **0.90 GiB** | 7.59+0.90+0.02+1.2 = **9.70** | **T1(i)** | (0.713+6.873×8/128)=1.143 GiB→4.1+2 ≈ **164 t/s** | – / – / **TB-2.1 27.70**; BFCL-v4 62.72, TAU3-Banking 20.8, ArtifactsBench 47.93 | Very new arch (3 weeks in llama.cpp); MLA+FA Vulkan bug #28124 |
| 9 | moonshotai/Kimi-VL-A3B-Thinking-2506 (2025-06-21, 16.4B) | 16.4B / 3B MoE (VL) | 27 L all MLA (576/tok), 64 exp top-6, **moe_int 1408 (not ×256 → fallback confirmed)** | 131,072 | thinking-only (◁think▷) | text `deepseek2` (PR #15051), mtmd #15458 | ggml-org/Kimi-VL-A3B-Thinking-2506-GGUF **Q4_K_M 9.817** (experts 8.873 = Q4_K 5.03 + **Q8_0 2.19 + Q5_0 1.65 fallback**) | 27×576×1.0625×262,144 = 4.33 GB = **4.03 GiB** | 9.64+4.03+1.2 = **14.87** | **T1(i)** (Q8_0 15.8 → T2, k=10, 2.66×) | (0.761+8.873×6/64)=1.593 GiB→5.7+2 ≈ **130 t/s** | none published (MMLU 82.0, MATH 91.8, GPQA 42.3) | No coding evidence; 2025 model; MLA FA bug #28124 |
| 10 | tencent/Youtu-LLM-2B (2025-12-31, 1.96B) | 2.0B dense MLA | 32 L all MLA (kv_lora 512 + rope 64; q_lora 1536), tied | 131,072 | "Reasoning Mode" via `enable_thinking=True` | `deepseek2` (`YoutuForCausalLM` registered, conversion/__init__.py L280) | tencent/Youtu-LLM-2B-GGUF (official) **Q8_0 1.946** (tok 0.260 tied) (F16 3.658 fits: 9.64) | 32×576×1.0625×262,144 = 5.13 GB = **4.78 GiB** | 1.94+4.78+1.2 = **7.92** | **T1(i)** | 1.942 GiB→7.0+2 ≈ **112 t/s** | **17.7 / 43.7 / –**; BFCL-V3 58.0, τ²-Bench 15.0 | Only official GGUF (no imatrix quants); MLA FA bug |
| 11 | openbmb/MiniCPM5-2B (2026-09-06, 2.52B) | 2.5B dense | 42 L, 2 kv×128, untied | 131,072 | deep-thinking SFT; `enable_thinking=True` in template | `llama` (LlamaForCausalLM) | openbmb/MiniCPM5-2B-GGUF (official) **Q8_0 2.496** (tok 0.265→CPU, out 0.265) (F16 4.693 fits: 10.97) | 42×512×1.0625×262,144 = 5.99 GB = **5.58 GiB** | 2.23+5.58+1.2 = **9.01** | **T1(i)** | 2.226 GiB→8.0+2 ≈ **100 t/s** | **46.4 / 69.1 / TB-2.1 8.6**; SWE-Pro 14.4, BFCL-v4 66.6, τ²-Telecom 97.1 | 5 days old; only 3 official quants; self-reported |
| 12 | Skywork/Skywork-OR1-7B (2025-05-13, 7.6B) | 7.6B dense (Qwen2.5-7B/R1-distill lineage) | 28 L, 4 kv×128, untied | 131,072 | always-on long CoT (no toggle documented) | `qwen2` | bartowski/Skywork_Skywork-OR1-7B-GGUF **Q6_K 5.825** (Q8_0 7.542 → 15.64 ✗) | 28×1024×1.0625×262,144 = 7.99 GB = **7.44 GiB** | 5.40+7.44+1.2 = **14.04** | **T1(i)** | 5.403 GiB→19.3+2 ≈ **47 t/s** | – / LCB(8/24–2/25) 47.6 Avg@4 / – | Math-RL model, no agentic training; old |
| 13 | zai-org/GLM-4.6V-Flash (2025-12-07, 10.3B, VL) | 10.3B dense (VL) | 40 L, 2 kv×128, untied | 131,072 ("128k in training") | `enable_thinking` / `<think>` / `/nothink` in chat_template.jinja | text `glm4` + mmproj (Glm4v registered) | unsloth/GLM-4.6V-Flash-GGUF **Q8_0 9.313** (tok 0.614→CPU) (Q6_K 7.699 → 13.73) | 40×512×1.0625×262,144 = 5.70 GB = **5.31 GiB** | 8.69+5.31+1.2 = **15.20** (0.3 GiB margin) | **T1(i)** | 8.69 GiB→31.1+2 ≈ **30 t/s** (Q6_K 36) | none in card (vision benchmarks only) | Thin VRAM margin; no coding numbers |
| 14 | baidu/ERNIE-4.5-21B-A3B-Thinking (2025-09-08, 21.8B) | 21.8B / 3B MoE | 28 L (27 MoE), 4 kv×128, 64 exp top-6 + 2 shared, moe_int 1536 (k-quant OK), tied | 131,072 | thinking-only ("increased thinking length") | `ernie4_5-moe` (PR #14658) | unsloth/ERNIE-4.5-21B-A3B-Thinking-GGUF **UD-IQ2_M 7.48** (experts 6.638/27 L = 0.246 GiB/L; other 0.640; tok 0.202 tied) | 28×1024×1.0625×262,144 = 7.99 GB = **7.44 GiB** | k=3 layers on CPU → 15.38 | **T2** (1.39×) — also needs YaRN×2 | 7.24→10.07 ms ≈ **99 t/s**; UD-IQ3_XXS k=7 2.01× 65 t/s; UD-Q4_K_XL 3.27× ✗ | – / – / – ; BFCL 65, HumanEval+ 90.85, MBPP 80.16 (benchmark.png) | No SWE/LCB/TB; needs YaRN + offload |
| 15 | zai-org/GLM-4.7-Flash (2026-01-19, 31.2B) | 31.2B / ~3B MoE | 47 L (46 MoE) all MLA 576/tok, 64 exp top-4 + 1 shared, moe_int 1536, MTP layer | **202,752** (→ RoPE ×1.29 for 262,144) | thinking + Preserved-Thinking; `--reasoning-parser glm45` | `deepseek2` via `Glm4MoeLiteForCausalLM` (conversion/glm.py L247; PR #19106) | unsloth/GLM-4.7-Flash-GGUF **UD-IQ2_M 10.24** (experts 8.770/46 = 0.191 GiB/L; other 1.050, out 0.242) | 47×576×1.0625×262,144 = 7.54 GB = **7.02 GiB** | k=15 → 15.42 | **T2** (2.02×) (ctx caveat) | 8.59→17.34 ms ≈ **58 t/s**; UD-IQ3_XXS k=20 2.47× 45 t/s; UD-Q4_K_XL 3.36× ✗ | **59.2 / 64.0 / –** (TB-2 mentioned, no number); τ²-Bench 79.5 | Not 256K native; heavy KV (MLA×47); MLA FA Vulkan bug |

One-liners (already analysed): **Qwen/Qwen3.5-9B** (2026-02-27, 9.65B; 32 L, 8 full × 4 kv×256 → KV **4.25 GiB**; unsloth Q8_0 8.873 GiB → 8.87+4.25+0.05+1.2 = 14.37 ≤ 15.5 → **T0 at Q8_0**, ~30 t/s; own LCB-v6 65.6, BFCL-V4 66.1, TAU2 79.1; TB-2.1 29.2 per Ling card). **Qwen/Qwen3.6-35B-A3B** (2026-04-15, same qwen35moe geometry → KV 2.66 GiB; unsloth UD-IQ2_M 10.731 GiB → ≈14.3 GiB → **T0**; UD-IQ3_XXS 12.304 → k≈1–2 → T1(ii); KAT card gives it SWE-V 64.40).

**Sources for table rows:** configs `https://huggingface.co/<repo>/raw/main/config.json`; cards `https://huggingface.co/<repo>`; GGUF trees `https://huggingface.co/api/models/<gguf-repo>/tree/main?recursive=true`. Benchmarks: Qwen3.5-4B/2B/0.8B/35B-A3B cards (https://huggingface.co/Qwen/Qwen3.5-4B, …/Qwen3.5-2B, …/Qwen3.5-35B-A3B), KAT (https://huggingface.co/Kwaipilot/KAT-Coder-V2.5-Dev), MiniCPM5-2B table incl. third-party Qwen3.5-2B/4B numbers (https://huggingface.co/openbmb/MiniCPM5-2B), Ling-3.0-tiny image `https://cdn-uploads.huggingface.co/production/uploads/6502cf8fbdaeae26417cd3c9/g9Thw4ohjkDGYw0Cq7mKi.png`, Youtu (https://huggingface.co/tencent/Youtu-LLM-2B), Hunyuan (https://huggingface.co/tencent/Hunyuan-1.8B-Instruct), Skywork (https://huggingface.co/Skywork/Skywork-OR1-7B), GLM-4.7-Flash (https://huggingface.co/zai-org/GLM-4.7-Flash), ERNIE `https://huggingface.co/baidu/ERNIE-4.5-21B-A3B-Thinking/resolve/main/benchmark.png`, GLM-4.6V-Flash template `https://huggingface.co/zai-org/GLM-4.6V-Flash/raw/main/chat_template.jinja`.

---

### 2. MoE tier arithmetic (per quant; bytes from GGUF headers; budget = 15.5 − 1.2 − KV − recurrent)

35B-A3B family (KAT / Qwen3.5-35B; budget 11.58 GiB; top_k/n = 8/256):

| quant | total | experts (GiB/L) | resident non-exp | k on CPU | VRAM | t_all→t_off (ms) | ratio | tier |
|---|---|---|---|---|---|---|---|---|
| KAT IQ2_M | 11.23 | 9.855 (0.246) | 1.169 | 0 | 14.94 | 7.29 | 1.00 | **T0** |
| KAT IQ3_XXS | 13.84 | 12.383 (0.310) | 1.253 | 7 | 15.39 | 7.87→11.45 | 1.46 | T2 |
| KAT IQ4_XS | 17.51 | 15.938 (0.398) | 1.316 | 15 | 15.19 | 8.49→17.51 | 2.06 | T2 |
| KAT Q4_K_M | 19.91 | 18.164 (0.454) | 1.482 | 18 | 15.39 | 9.34→21.16 | 2.27 | T2 |
| KAT Q6_K | 27.98 | 25.820 (0.645) | 1.771 | 25 | 15.37 | 11.23→32.47 | 2.89 | T2 (largest) |
| KAT Q8_0 | 34.37 | 31.875 (0.797) | 1.991 | 28 | 15.47 | 12.69→40.75 | 3.21 | ✗ |
| Q3.5-35B UD-IQ2_M | 10.60 | 8.984 (0.225) | 1.289 | 0 | 14.19 | 7.62 | 1.00 | **T0** |
| Q3.5-35B UD-IQ3_XXS | 12.17 | 10.234 (0.256) | 1.549 | 1 | 15.44 | 8.69→9.15 | 1.05 | **T1(ii)** |
| Q3.5-35B UD-Q4_K_XL | 20.71 | 18.22 (0.455) | 1.87 | 19 | 15.35 | 10.73→23.24 | 2.17 | T2 |
| Q3.5-35B Q6_K | 26.86 | 24.609 (0.615) | 1.748 | 25 | 14.89 | 11.01→31.49 | 2.86 | T2 |

Others: GLM-4.7-Flash (budget 7.28; 4/64): UD-IQ2_M k=15 2.02× T2; UD-IQ3_XXS k=20 2.47× T2; UD-Q4_K_XL k=28 3.36× ✗; Q6_K 4.15× ✗; Q8_0 4.52× ✗. ERNIE (budget 6.86; 6/64): UD-IQ2_M k=3 1.39× T2; UD-IQ3_XXS k=7 2.01× T2; UD-Q4_K_XL k=14 3.27× ✗; Q6_K 4.07× ✗; Q8_0 4.53× ✗. Kimi-VL (budget 10.27; 6/64): Q4_K_M k=0 T1(i); Q8_0 k=10 2.66× T2. Ling-3.0-tiny (budget 13.38): Q4_K_M/Q6_K/Q8_0 all k=0 (6.48/7.98/9.70 GiB). Qwen3-30B-A3B-Thinking-2507 (KV 48×1024 el = **12.75 GiB** → budget 1.55): UD-IQ2_M k=44/48 → 4.79×, UD-Q4_K_XL k=46 → 5.71× → **FAIL**. Kimi-Linear-48B-A3B (KV 7 MLA×576 = 1.05 GiB, KDA state 20×2 MiB): IQ2_M k=3 1.32× / IQ3_XXS k=8 1.92× / Q4_K_M k=15 2.97× — moot, FAIL(a).

---

### 3. FAIL table

| model | reason (one line) |
|---|---|
| Qwen/Qwen3-30B-A3B-Thinking-2507 (30.5B, 262K) | KV 48 L×4kv×128 = 12.75 GiB leaves 1.55 GiB; UD-IQ2_M needs 44/48 expert layers in RAM → 4.8× > 3× (T2 fails) |
| Kwai-Klear/GoLongRL-30B-A3B, Kwai-Keye/Keye-VL-2.0-30B-A3B | Qwen3-MoE geometry 48×4×128 (configs verified) → same 12.75 GiB KV → FAIL as above (Keye arch also unregistered) |
| moonshotai/Kimi-Linear-48B-A3B-Instruct (49.1B, 1M) | FAIL(a): instruct-only, README contains no thinking mode (0 mentions); would be T2 (IQ2_M k=3, 1.32×) |
| Qwen/Qwen3.5-27B, Qwen3.6-27B, Qwen3.8-27B (27.8B dense) | KV 16 full×4kv×256 = 8.50 GiB; smallest quant (UD-IQ2_XXS 7.99) + 8.5 + 0.1 + 1.2 = 17.8 > 15.5; dense can't offload |
| Qwen/Qwen3-4B-Thinking-2507, Kwai-Klear/GoLongRL-4B, tencent/Hunyuan-4B-Instruct, deepseek-ai/DeepSeek-R1-0528-Qwen3-8B, Kwai-Klear/Klear-Reasoner-8B, inclusionAI/ZwZ-8B/4B, XiaomiMiMo/MiMo-VL-7B-RL-2508 | dense 36 L×8kv×128 = 2048 el → KV 19.1 GiB > budget |
| tencent/Hunyuan-7B-Instruct | config max_pos **32,768** (README claims 256K) and 32 L×8kv×128 → KV 17.0 GiB → FAIL(c)+VRAM |
| ByteDance-Seed/Seed-OSS-36B-Instruct (512K) | dense 64 L×8kv×128 → KV 36.5 GB = 34 GiB |
| Qwen/QwQ-32B | ctx 40,960 (FAIL c) and 64×8×128 KV 34 GiB |
| Skywork-OR1-32B, Kwaipilot/KAT-Dev(-32B), baichuan-inc/Baichuan-M2-32B | dense 64×8×128 → KV 34 GiB |
| zai-org/GLM-Z1-9B-0414 (32K), GLM-4.1V-9B-Thinking (65,536) | FAIL(c) |
| XiaomiMiMo/MiMo-7B-RL (32K) / -0530 (64K) | FAIL(c); `MiMoForCausalLM` not in llama.cpp registry (only MiMoV2/V2Flash) |
| XiaomiMiMo/MiMo-V2.5 (311B), MiMo-V2-Flash (310B) | >50B |
| inclusionAI/Ring-mini-2.0 (16.3B) | config max_pos 32,768, no rope_scaling (README says 128K) → FAIL(c) |
| inclusionAI/Ring-mini-linear-2.0 (16.4B, 131K) | `BailingMoeLinearV2ForCausalLM` not registered in llama.cpp → FAIL(d) |
| inclusionAI/Ling-mini-2.0 | non-thinking, 32K → FAIL(a,c) |
| inclusionAI Ring-flash-2.0 (103B), Ring-flash-linear-2.0 (104B), Ling-2.6-flash (107B), Ling-3.0-flash (127B), Ring-1T | >50B |
| baidu/ERNIE-4.5-VL-28B-A3B-Thinking | `Ernie4_5_VLMoe*` not registered in llama.cpp → FAIL(d) |
| internlm/Intern-S1-mini | ctx 65,536 → FAIL(c) |
| internlm/Intern-S2-Preview (36.1B, thinking) | `InternS2PreviewForConditionalGeneration` not in mainline; no unsloth/bartowski/ggml-org/official GGUF → FAIL(d) |
| internlm/Intern-MemDec-4B, Qwen/Qwen-AgentWorld-35B-A3B | not chat/coding models (memory add-on / world model) → FAIL(a/b) |
| openbmb/MiniCPM4.1-8B | ctx 65,536 → FAIL(c) |
| stepfun-ai/Step3-VL-10B (65,536), Step-3.7-Flash (201B) | FAIL(c) / >50B |
| MiniMaxAI/MiniMax-M3 (427B); no ≤50B MiniMax text model in org listing | out of scope |
| meituan-longcat/LongCat-Flash-Lite (69B), LongCat-Next (74B) | >50B and not registered |
| Tiiny/SmallThinker-21B-A3B | 32K, non-thinking → FAIL(a,c) |
| Kwai-Klear/Klear-46B-A2.5B-Instruct | ctx 65,536; `KlearMoeForCausalLM` unregistered → FAIL(c,d) |
| Kwaipilot/KwaiCoder-AutoThink-preview (40.6B) | config.json fetch returned non-JSON (gated?) — **unverified**; dense 32B-class → expected KV FAIL |
| tencent/Hunyuan-A13B (80B), Hy3-preview (299B), Hy4-preview (780B); ContextPilot-8B/14B (ctx 40,960); Youtu-VL-4B-Instruct (ctx 32,768) | >50B / FAIL(c) |
| Qwen/Qwen3.8-Flash-Next (180B), Qwen3-Next-80B, Qwen3-Coder-Next (79.7B); DeepSeek-V4/V4.1-Flash; Kimi-K2.x, Kimi-Dev-72B; GLM-5.3-Flash (321B) | >50B |
| Qwen3.6/3.7/3.8 small | none exist in `https://huggingface.co/api/models?author=Qwen` as of 2026-09-11 (only Qwen3.6-27B, Qwen3.6-35B-A3B, Qwen3.8-27B, Qwen3.8-Flash-Next) |

---

### 4. llama.cpp Vulkan notes for passing archs (GitHub issue search, repo ggml-org/llama.cpp)

- **NVIDIA Turing specifics:** PR **#19290** "vulkan: disable coopmat1 flash attention on Nvidia Turing" (merged 2026-02-03) → FA on this GPU runs the **scalar** path unless the driver exposes NV_cooperative_matrix2 (unverified on FreeBSD). Open issue **#28124** (2026-08-31): "Vulkan flash attention silently ignores GGML_PREC_F32 on fp16-capable GPUs, causing long-context corruption for **MLA** models" — FA_SCALAR path → directly relevant to GLM-4.7-Flash, Kimi-VL, Ling-3.0-tiny, Youtu-LLM-2B at 262K. Old: #10764 rounding differences on Turing (closed 2024).
- **qwen35 / qwen35moe (GDN):** GDN Vulkan shader merged PR **#20334** (2026-03-12; +21% TG); fixes #20495 (SSM_CONV multi-GPU crash, from #20462 `vk::DeviceLostError` on Qwen3.5-35B-A3B), #20379 (SSM_CONV PP scaling), #22653 (fused SSM_CONV+ADD+SILU), #24581 (GDN S_v=16). Still open: **#27237** garbage output at batch 512 (AMD 7900 XTX, Qwen3.5-27B), #26795 decode collapse to 4 t/s on RDNA4 (stale), #27973/#27193/#20377/#20376 perf fusions. Closed/stale: #21888 (Intel Arc garbage), #24812 (RX590 garbage), **#23827 `-nkvo` gibberish** (don't use -nkvo — KV must be in VRAM anyway), #21608 crash when reasoning disabled via `--reasoning off` (use chat_template_kwargs instead), #21984 PP 2× slower than CUDA on small models, #27998 GDN pipeline compile hang on gfx1103. No NVIDIA-specific GDN reports found.
- **deepseek2/MLA (GLM-4.7-Flash, Kimi-VL, Youtu):** #18947 topk_moe fusion for GLM-4.7-Flash (merged), #19143 Intel A770 load failure (closed), #19255 odd speed vs depth on 7900 XTX (closed); plus #28124 above.
- **bailingmoe3 (Ling-3.0-tiny):** support merged 2026-08-17 (#26608); no Vulkan issues found yet (too new — risk).
- **ernie4_5-moe, hunyuan-dense, llama, qwen2, glm4:** zero Vulkan-titled issues (`"ERNIE Vulkan in:title"`, `"Hunyuan Vulkan in:title"` = 0).

---

### 5. Could not verify / caveats

1. **Tied-embedding placement**: loader duplicates `token_embd` as output (llama-model-loader.cpp L1154-1160); I assumed the duplicate lands in GPU memory and counted it (Qwen3.5-4B/2B/0.8B, Hunyuan-*, ERNIE, Youtu). If it stays on CPU, subtract ≤0.63 GiB.
2. **Speed model omits KV-cache reads** (e.g., 4.25 GiB q8 KV for Qwen3.5-4B at full 262K ≈ +15 ms/token) and MTP; real Turing/Vulkan tg will be lower (scalar FA).
3. GLM-4.7-Flash native ctx 202,752 — needs ×1.29 RoPE scaling; quality unverified; classified T2 with caveat.
4. ERNIE-4.5-21B-A3B-Thinking and Ling-3.0-tiny benchmarks exist only as images (no SWE-bench Verified / LCB-v6 for either); ERNIE at 262K requires YaRN ×2 (card says 128K).
5. Kimi-VL-A3B-Thinking-2506 and GLM-4.6V-Flash: no coding benchmarks anywhere in cards; GLM-4.6V-Flash thinking control inferred from chat_template.jinja only.
6. Hunyuan-7B "256K" and Ring-mini-2.0 "128K" README claims contradict config.json (32,768) — config used.
7. KwaiCoder-AutoThink-preview config not retrievable; Intern-S2-Preview benchmarks image-only.
8. Qwen3.5-9B `tie_word_embeddings` not checked (T0 either way); Qwen3.6-35B-A3B numbers taken from tree sizes only (no header split).
9. Third-party Qwen3.5-2B/4B SWE-V/TB numbers come from the MiniCPM5-2B card (column mapping cross-checked via BFCL-V4 43.6 match with Qwen's own card; TB-2.1 25.8 for 4B matches Ling card).
10. Terminal-Bench / Aider numbers are absent for every model except KAT, Qwen3.5-35B-A3B, Ling-3.0-tiny, MiniCPM5-2B, and third-party Qwen3.5-4B/9B; no Aider scores found for any model.