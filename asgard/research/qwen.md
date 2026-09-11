Agent is idle (waiting for messages). agent_id: c33b032f-7b2e-4191-afee-0ba91926f49c, agent_type: research, status: idle, description: Research Qwen coder model specs, elapsed: 1340s, total_turns: 1

[Turn 0]
## Summary

All 9 requested Qwen repos exist on HF, and I found **5 newer open-weight releases** in the Qwen org that were not on your list: **Qwen3.6-35B-A3B** (Apr 15 2026), **Qwen3.6-27B** (Apr 21), **Qwen3.8-27B** (Aug 5), **Qwen3.8-2.4T-A95B** (Aug 8), **Qwen3.8-Flash-Next** (Aug 24; arch `qwen4_exp`, "preview of the architecture that will underpin Qwen4"). **No** `Qwen3.5-Coder*`, `Qwen3.6-Coder`, `Qwen3.7-*` (Qwen3.7-Plus/Max are API-only), `Qwen3.8-35B-A3B`, or `Qwen/Qwen4*` repos exist (HTTP 401/not found). Every Qwen3.5+ model is a hybrid **3×Gated-DeltaNet : 1×full-attention** stack with `max_position_embeddings=262144` and a trained 1-layer MTP head; the old Qwen3-30B-A3B models are full-attention everywhere (KV cache 24 GiB f16 @262k — the deal-breaker). Of the models that pass all four hard requirements *and* fit a 16 GB GPU + 128 GiB RAM box, the realistic candidates are **Qwen3.6-35B-A3B** (best fit; SWE-bench Verified 73.4, TB2.0 51.5), **Qwen3.5-122B-A10B** (SWE-V 72.0, TB2 49.4; experts in RAM), and — with caveats (Vulkan sparse-attention & MTP not mainline yet, ~90–104 GiB) — **Qwen3.8-Flash-Next** (SWE-bench Pro 62.5, LCB 91.9). Qwen3-Coder-Next and Qwen3-Coder-30B are **non-thinking only** (fail req. a); Qwen3-Next-80B-A3B-Thinking is superseded.

---

## 1. Compact table

| Model (HF `Qwen/…`) | Arch / llama.cpp arch | Total / active | Layers (full-attn) | KV heads × head_dim | Native ctx | Thinking control | MTP | SWE-V / TB / LCB-v6 / tool | UD-Q4_K_XL GiB (experts ∥ rest) | KV @262k f16 / q8_0 |
|---|---|---|---|---|---|---|---|---|---|---|
| **Qwen3.5-35B-A3B** | `qwen3_5_moe` / `qwen35moe` | 35B / 3B | 40 (10) | 2×256 | 262,144 | on by default; `enable_thinking:false`; no `/think` | yes; unsloth `-MTP-GGUF` | 69.2 / TB2 40.5 / 74.6 / BFCL-V4 67.3, TAU2 81.2 | 20.71 (18.1 ∥ 2.4) | 5.00 / 2.66 GiB |
| **Qwen3.6-35B-A3B** ★ | same | 35B / 3B | 40 (10) | 2×256 | 262,144 | + `preserve_thinking` (opt-in) | yes; unsloth `-MTP-GGUF` | 73.4 / TB2 51.5 / 80.4 / TAU3 67.2 | 20.82 (18.3 ∥ 2.5) | 5.00 / 2.66 GiB |
| Qwen3.5-27B (dense) | `qwen3_5` / `qwen35` | 27B / 27B | 64 (16) | 4×256 | 262,144 | as 3.5 | yes; `-MTP-GGUF` | 72.4 / TB2 41.6 / 80.7 / BFCL 68.5, TAU2 79.0 | 16.41 (0 ∥ 16.4) | 16.0 / 8.5 GiB |
| Qwen3.6-27B (dense) | same | 27B | 64 (16) | 4×256 | 262,144 | as 3.6 | yes; `-MTP-GGUF` | 77.2 / TB2 59.3 / 83.9 / — | 16.40 | 16.0 / 8.5 GiB |
| **Qwen3.8-27B** (dense) | same (`qwen35`) | 27B | 64 (16) | 4×256 | 262,144 | + `reasoning_effort` xhigh/medium/low, `preserve_thinking` default on | yes; **embedded in unsloth GGUF** (`nextn_predict_layers=1`) | SWE-Pro 61.7 / TB2.1 73.0 / 90.3 / Toolathlon 67.1 (no SWE-V on card) | 16.35 (0 ∥ 16.4; dense FFN 10.1) | 16.0 / 8.5 GiB |
| **Qwen3.5-122B-A10B** | `qwen35moe` | 122B / 10B | 48 (12) | 2×256 | 262,144 | as 3.5 | yes; `-MTP-GGUF` | 72.0 / TB2 49.4 / 78.9 / BFCL 72.2, TAU2 79.5 | 71.74 (65.5 ∥ 6.2) | 6.00 / 3.19 GiB |
| Qwen3.5-397B-A17B | `qwen35moe` | 397B / 17B | 60 (15) | 2×256 | 262,144 | as 3.5 | yes | 76.4 / TB2 52.5 / 83.6 / BFCL 72.9, TAU2 86.7 | 228.4 (Q3_K_XL 166; IQ2_M 114.6) | 7.50 / 3.98 GiB |
| **Qwen3.8-Flash-Next** | `qwen4_exp` / `qwen4exp` | 125B / 6B **+51B n-gram embd +4B MTP** | 48 (12 QSA sparse) | 2×256 (+indexer 1×128) | 262,144 | `enable_thinking`, `preserve_thinking`, `reasoning_effort` | yes; heads shipped, **not usable in mainline** | SWE-Pro 62.5 / DeepSWE 58.7 / 91.9 / Toolathlon 73.5 (no SWE-V/TB) | 103.7 (71.7 experts ∥ 26.8 n-gram ∥ 5.1 rest); IQ4_XS 87.3 | 6.00 / 3.19 GiB (+0.75 indexer-K f16) |
| Qwen3-Coder-Next (80B-A3B) | `qwen3_next` / `qwen3next` | 80B / 3B | 48 (12) | 2×256 | 262,144 | **non-thinking only** ✗ | trained; llama.cpp support, no public MTP GGUF | 70.6 / TB2 36.2 / — / Aider 66.2 | 46.20 (43.7 ∥ 2.5) | 6.00 / 3.19 GiB |
| Qwen3-Next-80B-A3B-Thinking | `qwen3next` | 80B / 3B | 48 (12) | 2×256 | 262,144 | thinking-only | as above | — / — / 68.7 / BFCL-v3 72.0, TAU2-retail 67.8 | 42.78 (41.3 ∥ 1.5) | 6.00 / 3.19 GiB |
| Qwen3-30B-A3B-Thinking-2507 | `qwen3_moe` / `qwen3moe` | 30.5B / 3.3B | 48 (**48**) | 4×128 | 262,144 | thinking-only | none | — / — / 66.0 / BFCL-v3 72.4 | 16.50 (15.5 ∥ 1.0) | **24.0 / 12.75 GiB** |
| Qwen3-Coder-30B-A3B-Instruct | `qwen3moe` | 30.5B / 3.3B | 48 (48) | 4×128 | 262,144 | **non-thinking only** ✗ | none | card has no numeric table | 16.45 | **24.0 / 12.75 GiB** |
| Qwen3.8-2.4T-A95B | `qwen3_5_moe` (text-only) | 2.4T / 95B | 92 (23) | 4×256 | 262,144 | 3.8-style | yes | TB2.1 86.6 / SWE-Pro 67.7 | n/a (BF16 ≈ 4.4 TiB) — not local | 23.0 / 12.2 GiB |

★ = my pick for your hardware. "rest" = attention + GDN + shared expert + embeddings + output head, from parsing actual GGUF tensor headers (see §3).

---

## 2. Architecture details (verified from `config.json`)

Common to all Qwen3.5/3.6/3.8 (`text_config`): `full_attention_interval: 4`, `layer_types` = 3×`linear_attention` then 1×`full_attention`, `head_dim: 256`, `attn_output_gate: true`, `partial_rotary_factor: 0.25` (RoPE on 64 of 256 dims), `rope_theta: 1e7`, interleaved M-RoPE `mrope_section [11,11,10]`, `linear_conv_kernel_dim: 4`, `linear_key_head_dim: 128`, `linear_num_key_heads: 16`, `linear_value_head_dim: 128`, `mamba_ssm_dtype: float32`, `mtp_num_hidden_layers: 1`, `vocab_size: 248320`, `max_position_embeddings: 262144`, `rope_type: default` (no YaRN in the shipped config).

- **Qwen3.5-35B-A3B / Qwen3.6-35B-A3B** — https://huggingface.co/Qwen/Qwen3.5-35B-A3B/blob/main/config.json , https://huggingface.co/Qwen/Qwen3.6-35B-A3B/blob/main/config.json : `num_hidden_layers 40` (30 linear + 10 full), `hidden_size 2048`, `num_attention_heads 16`, `num_key_value_heads 2`, `num_experts 256`, `num_experts_per_tok 8`, `moe_intermediate_size 512`, `shared_expert_intermediate_size 512`, `linear_num_value_heads 32`. Card: "Hidden Layout: 10 × (3 × (Gated DeltaNet → MoE) → 1 × (Gated Attention → MoE))", "MTP: trained with multi-steps", "Context Length: 262,144 natively and extensible up to 1,010,000" (README lines 54–72).
- **Qwen3.5-27B / Qwen3.6-27B / Qwen3.8-27B** (dense): `num_hidden_layers 64` (48+16), `hidden_size 5120`, `intermediate_size 17408`, `num_attention_heads 24`, `num_key_value_heads 4`, `linear_num_value_heads 48`. Qwen3.6/3.8 add `output_gate_type: swish`. Qwen3.8-27B config is byte-identical in shape to 3.6-27B (`transformers_version 5.8.0.dev0`) — https://huggingface.co/Qwen/Qwen3.8-27B/blob/main/config.json
- **Qwen3.5-122B-A10B** — https://huggingface.co/Qwen/Qwen3.5-122B-A10B/blob/main/config.json : 48 layers (36+12), `hidden_size 3072`, heads 32, kv 2, 256 experts top-8, `moe_intermediate_size 1024`, shared 1024, `linear_num_value_heads 64`.
- **Qwen3.5-397B-A17B** — https://huggingface.co/Qwen/Qwen3.5-397B-A17B/blob/main/config.json : 60 layers (45+15), `hidden_size 4096`, heads 32, kv 2, **512 experts top-10**, moe_inter 1024.
- **Qwen3.8-Flash-Next** — https://huggingface.co/Qwen/Qwen3.8-Flash-Next/blob/main/config.json : `architectures ["Qwen4ExpForConditionalGeneration"]`, `model_type qwen4_exp`, 48 layers (36 GDN + 12 **Qwen Sparse Attention**), `hidden_size 2560`, heads 24, kv 2, 512 experts top-10, `moe_intermediate_size 640`, `linear_num_value_heads 48`, `output_gate_type: sigmoid`; new fields `hc_count 4, hc_lowrank 320` (Gated Residual / hyper-connections), `indexer_budget 2048, indexer_compress_ratio 4, indexer_head_dim 128, indexer_n_heads 4, indexer_kv_heads 1` (QSA block-sparse), `ngram_size 3, ngram_vocab_size_base 20000000, heads_per_ngram 8, ple_layer_ids [2], ple_embed_dim 2560` (n-gram per-layer embedding). Card (README lines 45–70): "125B with 6B activated, plus 51B n-gram embedding and 4B MTP … Budget: 512 blocks or 2048 tokens … MTP: 1 layer".
- **Qwen3-Coder-Next / Qwen3-Next-80B-A3B-Thinking** — https://huggingface.co/Qwen/Qwen3-Coder-Next/blob/main/config.json : `Qwen3NextForCausalLM`, 48 layers (36+12), hidden 2048, heads 16, kv 2, head_dim 256, 512 experts top-10, moe_inter 512, `rope_theta 5e6` (Coder-Next) / `1e7` (Thinking), `rope_scaling: null`, vocab 151936.
- **Qwen3-30B-A3B-Thinking-2507 / Qwen3-Coder-30B-A3B-Instruct** — https://huggingface.co/Qwen/Qwen3-30B-A3B-Thinking-2507/blob/main/config.json : `Qwen3MoeForCausalLM`, 48 layers **all full attention**, heads 32, kv 4, head_dim 128, 128 experts top-8, `max_position_embeddings 262144`, `rope_scaling: null`.

**Thinking-mode toggles (from cards/templates):**
- Qwen3.5: "operate in thinking mode by default, generating `<think>\n...</think>\n\n`" (35B README:897); disable via `"chat_template_kwargs": {"enable_thinking": False}` (:1179); "Qwen3.5 does not officially support the soft switch of Qwen3, i.e., `/think` and `/nothink`" (:1142).
- Qwen3.6: same + `preserve_thinking` (opt-in; README "You can enable this behavior by setting the `preserve_thinking` option", Qwen3.6-35B:811–828).
- Qwen3.8 (27B, Flash-Next): `enable_thinking` (default on), `preserve_thinking` (default **on**), `reasoning_effort` = `xhigh` (default) | `medium` | `low` (Qwen3.8-27B README:257–263). Implemented in `chat_template.jinja` lines 46–56 as a system-prompt instruction ("Reasoning effort is set to xhigh…"), with `raise_exception` for other values — https://huggingface.co/Qwen/Qwen3.8-27B/blob/main/chat_template.jinja
- Qwen3-Next-80B-A3B-Thinking / Qwen3-30B-A3B-Thinking-2507: "supports only thinking mode". Qwen3-Coder-Next / Qwen3-Coder-30B-A3B-Instruct: "supports only non-thinking mode and does not generate `<think></think>` blocks" → fail requirement (a).

---

## 3. KV cache & recurrent-state arithmetic

Formula: bytes/token = 2 (K+V) × n_full_attn_layers × n_kv_heads × head_dim × bytes/elem; f16 = 2 B, q8_0 = 34 B per 32 elems = 1.0625 B. ×262,144 tokens.

| Model | elems/token | f16 B/tok | f16 @262k | q8_0 B/tok | q8_0 @262k |
|---|---|---|---|---|---|
| 35B-A3B (10 layers × 2 kv × 256) | 2·10·2·256 = 10,240 | 20,480 (20 KiB) | 5,368,709,120 B = **5.00 GiB** | 10,880 | 2,852,126,720 B = **2.66 GiB** |
| 27B dense (16 × 4 × 256) | 32,768 | 65,536 (64 KiB) | **16.00 GiB** | 34,816 | **8.50 GiB** |
| 122B-A10B, Coder-Next, Next-80B, Flash-Next (12 × 2 × 256) | 12,288 | 24,576 (24 KiB) | **6.00 GiB** | 13,056 | **3.19 GiB** |
| 397B-A17B (15 × 2 × 256) | 15,360 | 30,720 | 7.50 GiB | 16,320 | 3.98 GiB |
| Qwen3-30B-A3B-* (48 × 4 × 128) | 49,152 | 98,304 (96 KiB) | 25,769,803,776 B = **24.00 GiB** | 52,224 | **12.75 GiB** |
| Qwen3.8-2.4T (23 × 4 × 256) | 47,104 | 94,208 | 23.0 GiB | 50,048 | 12.2 GiB |

Flash-Next extra: QSA indexer K cache = 12 layers × 1 head × 128 = 1,536 elems/token → 3,072 B/tok f16 → **0.75 GiB @262k** (V cache for indexer no longer allocated since PR #28330, b10889; whether `-ctk` quantization applies to it is unverified).

**GDN fixed state (per sequence, f32, context-independent)** — from GGUF hparams `ssm.inner_size (d_inner) / ssm.state_size 128 / ssm.group_count 16 / ssm.conv_kernel 4`: S = 128 × d_inner floats; conv = 3 × (d_inner + 2·16·128) floats.
- 35B-A3B: d_inner 4096 → 2 MiB + 96 KiB per layer × 30 = **≈63 MiB**
- 27B: d_inner 6144 → 3 MiB + 120 KiB × 48 = **≈146 MiB**
- 122B: d_inner 8192 → 4 MiB + 144 KiB × 36 = **≈149 MiB**; 397B ×45 ≈ 186 MiB
- Coder-Next/Next-80B: 4096 → ×36 ≈ 75 MiB; Flash-Next: 6144 → ×36 ≈ 112 MiB
Caveat: llama-server creates context checkpoints for hybrid models (each a full copy of that state) — README default `--ctx-checkpoints 32` per slot → up to 32×146 MiB ≈ 4.6 GiB host RAM per slot for a 27B; tune `-ctxcp` down.

---

## 4. GGUF sizes (GiB, from HF tree API; unsloth unless noted)

| Quant | 3.5-35B-A3B | 3.6-35B-A3B | 3.5-27B | 3.6-27B | 3.8-27B | 3.5-122B-A10B | 3.5-397B | 3.8-Flash-Next | Coder-Next | Next-80B-Think | 30B-A3B-Think-2507 | Coder-30B |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Q8_0 | 34.37 | 34.37 | 26.63 | 26.63 | 27.05 | 120.95 | 392.6 | 181.75 | 78.99 | 78.99 | 30.25 | 30.25 |
| Q6_K / UD-Q6_K | 26.87 | 27.30 | 20.91 | 20.98 | 20.47 | 94.07 | 304.2 | UD-Q6_K_XL 157.6 | 61.11 | 61.04 | 23.37 | 23.37 |
| UD-Q5_K_XL / Q5_K_M | 24.57 / 24.45 | 24.77 / 24.64 | 18.79 / 18.26 | 18.66 / 18.17 | 19.44 / 18.41 | 85.61 / 85.23 | 274.6 / 273.5 | 147.4 / — | 55.45 / 52.94 | 52.77 / 52.91 | 20.27 / 20.23 | 20.25 / 20.23 |
| UD-Q4_K_XL / Q4_K_M | 20.71 / 20.50 | 20.82 / 20.61 | 16.41 / 15.59 | 16.40 / 15.66 | 16.35 / 15.33 | 71.74 / 71.28 | 228.4 / 227.3 | **103.69** / — | 46.20 / 45.20 | 42.78 / 45.17 | 16.50 / 17.28 | 16.45 / 17.28 |
| (UD-)IQ4_XS | 16.29 | 16.51 | 13.95 | 14.38 | 13.27 | 56.09 | 176.7 | **87.25** | 35.79 | 39.72 | 15.25 | 15.25 |
| Q3_K_M / UD-Q3_K_XL | 15.23 / 15.46 | 15.46 / 15.69 | 12.58 / 13.45 | 12.65 / 13.48 | — / 12.24 | 52.55 / 53.06 | 165.2 / 166.5 | — / 83.81 | 35.69 / 33.79 | 35.67 / 33.06 | 13.70 / 12.88 | 13.70 / 12.86 |

Listings: https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF/tree/main · https://huggingface.co/unsloth/Qwen3.5-122B-A10B-GGUF/tree/main · https://huggingface.co/unsloth/Qwen3.8-27B-GGUF/tree/main · https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/tree/main · https://huggingface.co/unsloth/Qwen3-Coder-Next-GGUF/tree/main · https://huggingface.co/unsloth/Qwen3-Next-80B-A3B-Thinking-GGUF/tree/main · https://huggingface.co/unsloth/Qwen3-30B-A3B-Thinking-2507-GGUF/tree/main
MTP variants (+~0.5 GiB): https://huggingface.co/unsloth/Qwen3.6-35B-A3B-MTP-GGUF (UD-Q4_K_XL 21.28, UD-IQ4_XS 16.96, Q8_0 35.21), unsloth/Qwen3.5-35B-A3B-MTP-GGUF, unsloth/Qwen3.5-27B-MTP-GGUF, unsloth/Qwen3.6-27B-MTP-GGUF (UD-Q4_K_XL 16.68), unsloth/Qwen3.5-122B-A10B-MTP-GGUF (UD-Q4_K_XL 73.25, UD-IQ4_XS 57.67). No `unsloth/Qwen3-Coder-Next-MTP-GGUF`, `…Next-80B-A3B-Thinking-MTP-GGUF`, or `…Qwen3.8-27B-MTP-GGUF` (401) — Qwen3.8-27B's main GGUF already embeds the MTP layer (`block_count=65`, `qwen35.nextn_predict_layers=1`).
bartowski (exist: `bartowski/Qwen_Qwen3.5-35B-A3B-GGUF`, `…3.6-35B-A3B`, `…3.5-27B`, `…3.6-27B`, `…3.5-122B-A10B`, `…Qwen3-Coder-Next`, `…Qwen3-Next-80B-A3B-Thinking`, `…Qwen3-30B-A3B-Thinking-2507`; **not** 3.8-27B / Flash-Next / Coder-30B): Qwen3.6-35B-A3B Q8_0 37.07, Q6_K 28.82, Q5_K_M 24.13, Q4_K_M 20.75, IQ4_XS 18.35, Q3_K_M 15.94; Qwen3.6-27B Q8_0 30.06 … IQ4_XS 14.70, Q3_K_M 13.80; 122B Q8_0 123.49, Q4_K_M 72.29, IQ4_XS 63.77.
Official Qwen GGUFs: `Qwen/Qwen3-Coder-Next-GGUF` and `Qwen/Qwen3-Next-80B-A3B-Thinking-GGUF` (Q4_K_M 45.09, Q5_K_M 52.82, Q6_K 61.03, Q8_0 78.99, F16 ~148). No official GGUF for Qwen3.5+.

**Expert vs. non-expert split (parsed from GGUF tensor headers, UD-Q4_K_XL):**
- Qwen3.6-35B-A3B: routed experts **18.32** ∥ shexp 0.12 + attn 0.27 + GDN 1.01 + embd 0.50 + output 0.50 + norms 0.08 = **2.5 GiB** → with `--cpu-moe` GPU holds 2.5 + KV(5.0 f16 / 2.66 q8_0) → ~8 GiB free on a 16 GB card for ≈15 layers of experts (0.46 GiB/layer) via `--n-cpu-moe 25`.
- Qwen3.5-122B-A10B: experts **65.54** ∥ rest **6.2** (shexp 0.45, attn 0.93, GDN 3.16, embd/output 0.75 each) → GPU ≈ 6.2 + 3.19 (q8_0) + state 0.15 + buffers ≈ 11 GiB ✔; 65.5 GiB experts in RAM ✔ (128 GiB).
- Qwen3-Coder-Next: experts **43.69** ∥ rest 2.5; Next-80B-Thinking: 41.25 ∥ 1.5.
- Qwen3.8-Flash-Next: experts **71.73** ∥ `per_layer_token_embd.weight` (IQ4_NL, 160×320,001,536) **26.82** ∥ rest 5.1 (attn 0.91, GDN 2.09, shexp 0.23, embd/output 0.63 each, hc/indexer/norms 0.63). The n-gram table is looked up host-side (`ggml_get_rows` with CPU row indices, PR #27742) so it can stay in RAM: 98.5 GiB RAM + ~5 GiB VRAM + KV; UD-IQ4_XS (87.25 total) is the safer choice for 128 GiB.
- Qwen3.8-27B (dense): dense FFN 10.09 ∥ attn 1.15 + GDN 3.42 + embd 0.67 + output 0.97 = 6.2 GiB → `--n-cpu-ffn` offload leaves 6.2 + 8.5 (q8_0 @262k) ≈ 14.7 GiB VRAM — tight, and a dense 27B FFN on DDR4 will be very slow; not recommended for 262k.
- Qwen3-30B-A3B-*: experts 15.54 ∥ rest 1.0, but KV alone is 12.75 GiB q8_0 / 24 GiB f16 at 262k → effectively disqualified.

---

## 5. Coding benchmarks (official cards)

- **Qwen3.5-35B-A3B card** (table also lists 122B & 27B; https://huggingface.co/Qwen/Qwen3.5-35B-A3B): SWE-bench Verified 69.2 / 72.0 (122B) / 72.4 (27B); Terminal Bench 2 40.5 / 49.4 / 41.6; LiveCodeBench v6 74.6 / 78.9 / 80.7; BFCL-V4 67.3 / 72.2 / 68.5; TAU2-Bench 81.2 / 79.5 / 79.0; CodeForces 2028 / 2100 / 1899. No Aider.
- **Qwen3.5-397B-A17B**: SWE-V 76.4, SWE Multilingual 69.3, TB2 52.5, LCB v6 83.6, BFCL-V4 72.9, TAU2 86.7, SecCodeBench 68.3.
- **Qwen3.6-35B-A3B**: SWE-V **73.4**, SWE-Multilingual 67.2, SWE-Pro 49.5, TB2.0 **51.5**, TAU3-Bench 67.2, Tool Decathlon 26.9, LCB v6 80.4 (footnote: TB2 via Harbor/Terminus-2, 256K ctx, avg of 5 runs).
- **Qwen3.6-27B**: SWE-V **77.2**, SWE-Pro 53.5, Multilingual 71.3, TB2.0 **59.3**, LCB v6 83.9.
- **Qwen3.8-27B** (new benchmark set; no SWE-V/TB2.0): Terminal Bench 2.1 (Terminus) **73.0** (3.6-27B: 63.4), SWE-bench Pro **61.7**, DeepSWE 1.1 42.2, QwenSWEBench 79.0, NL2Repo 42.3, LCB v6 90.3, Toolathlon Verified 67.1 (from Flash-Next table), IFBench 79.5.
- **Qwen3.8-Flash-Next**: SWE-Pro **62.5**, DeepSWE 1.1 **58.7**, SWE-Multilingual **81.0**, NL2Repo 48.1, LCB v6 **91.9**, Toolathlon Verified 73.5, CoWorkBench 73.9, GPQA 91.7 (vs Claude-Opus-4.6 Max 53.4 SWE-Pro).
- **Qwen3-Coder-Next** (chart image on card, read by me: https://qianwen-res.oss-accelerate-overseas.aliyuncs.com/Qwen3-Coder-Next/benchmarks.png): SWE-V 70.6, SWE-Multilingual 62.8, SWE-Pro 44.3, TB2.0 36.2, **Aider 66.2**.
- **Qwen3-Next-80B-A3B-Thinking**: LCB v6 68.7, BFCL-v3 72.0, TAU2 retail/airline/telecom 67.8/60.5/43.9. No SWE-V.
- **Qwen3-30B-A3B-Thinking-2507**: LCB v6 66.0, BFCL-v3 72.4, TAU2 58.8/58.0/26.3. No SWE-V. Coder-30B card has only images/no table.
- **Qwen3.8-2.4T-A95B**: TB2.1 86.6, SWE-Pro 67.7, DeepSWE 56.6 — API-scale only.

---

## 6. llama.cpp status (mainline `ggml-org/llama.cpp`, checked 2026-09-11)

| Arch | Added by | Tag | Notes |
|---|---|---|---|
| `qwen3moe` | Qwen3 launch (Apr 2025) | old | mature |
| `qwen3next` | PR #16095 "Model: Qwen3 Next" merged 2025-11-28 | **b7186** | perf follow-ups #17587, #17996, #18683, #19324, #19375; MTP #25589 (2026-08-03, **b10238**, `--spec-type draft-mtp`, needs GGUF converted with `--mtp`) |
| `qwen35` / `qwen35moe` | PR #19468 "[MODEL] support qwen3.5 series" merged 2026-02-10 | **b7990** | fixes #19730, #20126; MTP for any MTP model PR #22673 merged 2026-05-16 (**b9180**, tested on Qwen3.6-27B & 35B-A3B, "~75% acceptance, >2× speed-up"); EAGLE3 drafts #24593; explicit `recurrent_layers` in converter #28208 (2026-09-07) |
| `qwen4exp` | PR #27742 "model: add Qwen3.8-Flash-Next (qwen4exp)" merged 2026-08-27 | **b10660** | follow-ups #27880, #27941, #28023, #28123 (state rollback), #28330 (2026-09-10, **b10889**). **MTP for qwen4exp NOT merged**: PRs #27836 and #28243 open; unsloth's `MTP/README.md` states "A stock ggml-org/llama.cpp build cannot use these" (use unsloth fork ≥ `b10715-mix-86bd2d3` or build PR #28243). CUDA sparse-FA for DSA landed (#27970, 2026-09-02) but "QSA (qwen4) can be enrolled at a later stage"; **Vulkan sparse FA still open (#28105)**. |

Chat/tool/reasoning plumbing: `common/chat.cpp:1194-1200` detects the XML tool-call template (`<tool_call><function=…><parameter=…>`) — "Qwen3-Coder XML tool calls, also used by Nemotron Nano 3, Qwen3.5 and StepFun-3.5-Flash" → applies to Qwen3.5/3.6/3.8/Flash-Next/Coder-Next/Coder-30B (verified their `chat_template.jinja` contain those tags). Qwen3-Next-Thinking and 30B-A3B-Thinking-2507 use the older Hermes-style JSON `<tool_call>{"name":…,"arguments":…}` template. `chat.cpp:934-936` passes `reasoning_effort` into the Jinja context (`jinja::caps_apply_reasoning_effort`); server flags: `--reasoning-format`, `--reasoning-effort LEVEL` (xhigh/medium/low OK for Qwen3.8), `--reasoning-budget N`, `--chat-template-kwargs '{"enable_thinking":false,"preserve_thinking":true}'`, `--cpu-moe / --n-cpu-moe / --n-cpu-ffn`, `--fit`, `--spec-type draft-mtp` (tools/server/README.md lines 81–271).

**Vulkan-backend issues found (all reports are AMD/Intel/Apple; none NVIDIA-Turing-specific, which also means unverified there):**
- Vulkan `GATED_DELTA_NET` op merged #20334 (2026-03-12) + #24581; the **chunked prefill kernel #20377 is still a draft** ("Chunked dispatch is currently disabled… autoregressive path handles all token counts") → long-prompt GDN prefill on Vulkan is the sequential kernel.
- #26795 (open, stale): Qwen3.6-35B-A3B decode collapses to ~4 t/s after 64 tokens on RDNA4/RADV; q8_0 KV makes it worse (1.7 t/s).
- #27237 (open): Qwen3.5-27B garbage at `-b 512`, fine at 1024/4096 (RX 7900 XTX).
- #24519 (open) / #23321 (closed): `--no-kv-offload` → immediate EOS / gibberish for Qwen3.6-27B, Qwen3-Coder-Next, Qwen3.6-35B-A3B on Vulkan.
- #26817 (open): temp-0 tool calls nondeterministic for Qwen3.6-35B-A3B on Vulkan with prompt cache (Intel B60).
- #27022 (open): qwen3next-arch MoE with IQ1_M router tensors → zeros on Vulkan.
- #26945 (open): Vulkan crash offloading ≥2 repeating layers with qwen35moe on Strix Halo/Windows.
- Qwen3.8: #27560 (open) llama-server AV crash with default ctx-checkpoints, Windows/Vulkan/AMD; #27431 (open) crash loading UD-Q4_K_M on AMD R9700; #28158 (open) MTP/DFlash draft emits OOB token 248320 on Vulkan (AMD); #28280 (open) server slot livelock on "erasing old context checkpoint" with qwen4exp + prompt cache; #27939 (closed) qwen4exp RPC Vulkan GGML_ASSERT; #28160 (closed) `--lazy-mode auto` halved pp512 for qwen4exp.
- Recent Vulkan perf work relevant to you: #28426 dedicated IQ4_XS mat-vec shader (2026-09-09), #28457 "small M matrix optimizations for qwen" (2026-09-10), #28422 topk_moe fusion for prefill.

---

## 7. Per-model verdicts for your box (RTX 5000 16 GB Vulkan + 128 GiB DDR4, 8C/16T)

1. **Qwen3.6-35B-A3B** — passes a/b/c/d; best speed/quality/fit; use `unsloth/Qwen3.6-35B-A3B-MTP-GGUF` UD-Q4_K_XL (21.3 GiB) or Q5/Q6 with `--n-cpu-moe`, `-ctk q8_0 -ctv q8_0 -c 262144` (2.66 GiB KV), `--spec-type draft-mtp` (mainline since b9180), `--jinja`, `--reasoning-format deepseek`. Prefer Qwen3.6 over 3.5 (SWE-V 73.4 vs 70.0 on the same harness; TB2 51.5 vs 40.5).
2. **Qwen3.5-122B-A10B** — passes; strongest tool-use numbers of the local-feasible set (BFCL-V4 72.2, TAU2 79.5, TB2 49.4, SWE-V 72.0); UD-Q4_K_XL 71.7 GiB (65.5 GiB experts in RAM) or UD-IQ4_XS 56 GiB; 10B active over DDR4-2933 → expect single-digit-to-low-teens t/s. MTP GGUF available. Note there is **no Qwen3.6-122B** — 3.5 is the latest at this size.
3. **Qwen3.8-Flash-Next** — best open-weight Qwen coder that fits (barely): UD-IQ4_XS 87.3 GiB / UD-Q4_K_XL 103.7 GiB; mainline supports the arch (b10660+) but Vulkan lacks sparse-FA (#28105 open) and MTP is fork/PR-only; several open server/Vulkan issues (#28280, #28158). Treat as experimental for now.
4. **Qwen3.8-27B / 3.6-27B (dense)** — best 27B quality (TB2.1 73.0, SWE-Pro 61.7) and `reasoning_effort`, but 16 GiB f16 / 8.5 GiB q8_0 KV at 262k plus ~16 GiB weights cannot live on a 16 GB card; dense FFN on DDR4 is too slow. Only viable at ≤64–128k with `--n-cpu-ffn`.
5. **Qwen3.5-397B-A17B** — fits RAM only at ≤IQ2_M (114.6 GiB); not sensible.
6. **Qwen3-Coder-Next** (non-thinking ✗) and **Qwen3-Next-80B-A3B-Thinking** — architecture supported (b7186+, MTP b10238+ via self-conversion), but superseded by Qwen3.5/3.6-35B-A3B (fewer GiB, higher SWE-V) — Coder-Next's Aider 66.2 is the only Aider number Qwen publishes for these.
7. **Qwen3-30B-A3B-Thinking-2507 / Qwen3-Coder-30B-A3B-Instruct** — full-attention 48 layers → 24 GiB f16 / 12.75 GiB q8_0 KV at 262k (won't fit with weights); Coder-30B also non-thinking. Disqualified.
8. Bonus: `Qwen/Qwen-AgentWorld-35B-A3B` (2026-06-22) is an *environment-simulation world model* fine-tuned from Qwen3.5-35B-A3B-Base, not a coding agent — ignore.

## Gaps / uncertainties
- Qwen3.8-27B & Flash-Next cards do **not** report SWE-bench Verified, Terminal-Bench 2.0, BFCL or TAU (they moved to TB2.1/SWE-Pro/DeepSWE/Toolathlon); no Aider on any Qwen3.5+ card.
- Qwen3-Coder-Next numbers were read from the card's PNG chart (blog is JS-rendered/404); Coder-30B has no textual table.
- No NVIDIA/Turing Vulkan report for GDN models surfaced in title searches; the problems above are AMD/Intel/MoltenVK — behavior on your RTX 5000 is unverified.
- Whether the qwen4exp indexer cache honors `-ctk` quantization and how QSA is executed on Vulkan without #28105 (dense fallback vs CPU) were not verified in code.
- Build-tag mapping for the original `qwen3moe` support PR was not re-fetched (long-standing since April 2025).
- All sizes are HF-reported file sizes (GiB = 2^30); tensor-group splits use nominal bits-per-weight per quant type (total matched listed sizes within 0.05 GiB).