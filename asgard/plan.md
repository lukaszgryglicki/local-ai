# asgard/plan.md — local coding LLM on asgard (Dell Precision 7750)

Research-only plan for the best llama.cpp/Vulkan coding model on asgard.
Companion to `../readme.md` (tuxi stack) and `/data/ai/*.md` (3+ days of POC
research). Sources: `research/qwen.md`, `research/non-qwen.md`,
`research/llamacpp-vulkan.md`, `research/sweep-cn.md`, `research/sweep-west.md`
(verified against HF + llama.cpp master b10909, 2026-09-11).

## STATUS (2026-09-11 evening)

- DONE: hardware audit; model research incl. two wide sweeps (`research/`);
  ranked shortlist by tier (§4: T-1 North-Mini-Code, T0 Qwen3.6-35B-A3B, T0b
  KAT-Coder, T1, T2 Qwen3.8-Flash-Next); configs (§5); llama.cpp v0.4.0
  rebuilt natively with Vulkan (§6, `BUILD_RC=0` 19:06); §7 step 1
  (`--list-devices` sees the Quadro, coopmat2) and step 2 (`test-backend-ops`
  gate: 0 FAIL / ≈ 19 200 cases) done; the FreeBSD-nvidia **256 MiB pinned
  allocation cap** found and turned into rules (§6); `zroot/data/local-ai`
  dataset done.
- GATED (awaiting Łukasz's go-ahead): **no GGUF downloaded, no model run**.
- NEXT when unblocked: §7 step 4 onwards (North UD-IQ3_XXS download + smoke
  + 256K warm-up, 9B Q8_0 head-to-head, then T0/T0b, T1 grid, T2 on a master
  build).

## 1. Hardware budget (asgard, measured)

| part | facts | budget for LLM |
|---|---|---|
| CPU | Xeon W-10885M, 8C/16T Comet Lake; AVX2/FMA/F16C, **no AVX-512**. **Turbo is disabled in BIOS** (`IA32_MISC_ENABLE` 0x1a0 bit 38 set) → hard cap **2.4 GHz** on every core (HWP caps: highest 5.3 / guaranteed 2.4 / most-efficient 1.2 GHz; measured APERF/MPERF 2.3–2.65 GHz, 41–43 °C under a 16-thread compile — thermals are not the limiter). `hwpstate_intel` epp=100 (default) keeps ~1.4–1.6 GHz under sustained load, epp=0 holds 2.4 GHz. RAPL PL1 35 W / PL2 45 W (§8) | expert (MoE FFN) matmuls when offloaded; `-t 8` for tg (tuxi law 1: SMT kills tg), `-tb 16` for pp. Re-enabling Turbo in BIOS (Łukasz's call) is the single biggest CPU-path lever: +50–100 % clock headroom |
| RAM | 128 GiB DDR4-2933 (4 × 32 GiB Samsung SODIMM, 2 channels): theoretical 46.9 GB/s, expect **~35–40 GB/s** real | ≤ **~100 GiB** for experts (OS+X+ARC cap ≈ 6–8 GiB, headroom). The dockaws VM (40 GiB) **cannot** run alongside a ≥ 80 GiB model |
| dGPU | Quadro RTX 5000 (TU104 Turing), **16 GiB GDDR6 448 GB/s**, PCIe 3.0 x16 (~12 GB/s), nvidia 595.99.02, Vulkan 1.4.329: coopmat + NV coopmat2, fp16, int8-dot, subgroup 32; compute-only (X is on the iGPU) | ≈ **15.5 GiB** usable: non-expert weights + KV (q8_0 @ 262 144) + compute buffers + as many expert layers as fit |
| iGPU | Intel UHD P630 (ANV): no coopmat, subgroup 8, memory = the same DDR4 | expected **negative** as a split target (competes with the CPU path for the same 40 GB/s, slower kernels than AVX2). One measurement only (§5 C) |
| disk | zroot 4-way NVMe mirror, GELI. **`zroot/data/local-ai` is the model dataset** (swapped 2026-09-11 evening to mirror tuxi: `compression=off`, `primarycache=metadata`, recordsize/mountpoint inherited → `/data/local-ai`); `/data/ai` is a plain directory under `zroot/data` (zstd-13) like on tuxi | models go to `/data/local-ai/models/`; same reasoning as readme.md "ZFS: why the model has its own dataset". Loads are always `--load-mode none` here (§6 pinned cap), so `primarycache=metadata` only costs one sequential read per start |
| thermal | PCH idles ~95 °C, 101–103 °C under I/O (trips 108/111/114); CPU 42 °C idle | watch `sysctl dev.cpu.0.temperature hw.acpi.thermal` during grids; thermal-watchdog is installed |
| power | S3 works (`z` = `sudo zzz`); lid = display off/on only | **a server with GPU work in flight hangs forever after a resume** (fence wait, live test 2026-09-12 07:26, results-t1.md) → stop llama-server before your own `z`; the thermal watchdog's suspend does it automatically and restarts after (§6 rule 5, `ops.md`) |

## 2. Requirements (from Łukasz)

1. Thinking model, coding-specialised, **≥ 256K context** (native preferred;
   128K native + YaRN ×2 = 256K is *barely acceptable* and only if nothing
   native fits — currently moot, T0 fits natively).
2. Fast: "hot" parts (attention, GDN, shared expert, embeddings, KV) in Quadro
   VRAM; "cold" routed experts may live outside the Quadro **only if** the
   result is at most ~1.5–3× slower than the best all-VRAM layout.
3. **Placement order when a model does not fit the Quadro (owner rule,
   2026-09-12):** first try the Intel iGPU (Vulkan1, `IGPU_MOE=N` in serve.sh —
   shared DDR4, but it is still a Vulkan device), and only as the *last*
   resort plain CPU/RAM (`NCMOE=N`). Both are measured with sweeps at the same
   N, never guessed; the faster one wins (§5 C).
4. **Tiers (Łukasz's final definition, 2026-09-11):**
   - **T-1 — no compromises:** everything (weights, KV q8_0 @ 262 144,
     compute buffers) in the 16 GiB Quadro, native 256K, thinking, dev-focused;
     the largest quant that fits. Nothing in RAM.
   - **T0 — between T-1 and T1:** as T-1 but *either* a RAM-resident cold part
     costing ≤ 30 % tg, *or* 128K native + YaRN ×2 (only if nothing native
     fits — currently moot). Still thinking + dev-focused.
   - **T1:** RAM-resident experts at ≤ 1.5–3× slower than the all-VRAM layout.
   - **T2:** the bigger-model experiment — experts in the 128 GiB, quality first.
     **Status (owner, 12 Sep 11:23): kept as an option, decided at the very end** —
     T1 is already at the edge of usability, so T2 only happens if T1 leaves room.
   **Tight fits are the goal** in every tier: fill 95–100 % of VRAM (largest
   quant / most expert layers that still load at ctx 262 144) — the last GiB
   is not a safety margin to keep.
5. Everything documented here so the work can resume after a break.

## 3. Performance model (what to expect before measuring)

`tg ≈ 1 / ( active_expert_bytes / BW_cpu_path + (dense + KV bytes) / 448 GB/s + overhead )`

but tuxi showed the CPU expert path is **compute/latency-bound, not
bandwidth-bound**: Zen4 8C got 11 t/s shallow on Qwen3-Coder-30B-A3B Q8_0
(≈1.2 GB active experts/token; the DDR5 ceiling would have been ~45 t/s).
Comet Lake AVX2 at 1.4–1.6 GHz is roughly half a Zen4 core → assume
**CPU-only experts: A3B Q8 ≈ 5–9 t/s, A3B Q4 ≈ 8–14 t/s, A6B Q4 ≈ 4–7, A10B Q4
≈ 3–5**. Levers, multiplicative: VRAM-resident half of the expert layers
(+30–60 %), epp 100→0 (+? — measure), MTP+ngram-mod speculation (×1.5–2.5
effective, lossless). Unlike tuxi, KV/attention stay on the GPU, so the
depth decay (law 4) should largely disappear.

Per-token active routed-expert bytes (from config.json): Qwen3.6-35B-A3B
1.0 B params (8/256 × 40 layers) → 0.55 GB @ Q4_K_XL, 1.07 GB @ Q8_0;
Qwen3.8-Flash-Next 2.36 B (10/512 × 48) → 1.25 GB @ IQ4_XS; Qwen3.5-122B
3.6 B → 2.0 GB @ Q4.

## 4. Ranked shortlist

VRAM column = non-expert weights + KV q8_0 @ 262 144 + recurrent state
(+ ~1–1.5 GiB compute buffers not shown). Sizes from HF tree listings (GiB).
llama.cpp keeps `token_embd` on the CPU, **but tied-embedding models
(Cohere North, Gemma 4, small Qwens) get a GPU copy of it as `output`** —
verified for North from the GGUF header (442 tensors, no `output.weight`) —
so for those the whole file size counts against VRAM. Two wide sweeps
(`research/sweep-cn.md`, `research/sweep-west.md`, ~20 labs, sizes/configs
re-fetched from HF on 2026-09-11) feed this table.

| # | model (GGUF repo) | quant / size | thinking | native ctx | VRAM plan | RAM | exp. raw tg | coding scores | why / risks |
|---|---|---|---|---|---|---|---|---|---|
| **T-1** | **North-Mini-Code-1.0** (CohereLabs, 2026-06-05; `cohere2moe`: 49 layers = 1 dense + 48 MoE, 128 experts top-8 + shared, 13 full-attn (NoPE) + 36 SWA-4096, kv 4 × 128, vocab 262 144, tied embeddings, no MTP) — `unsloth/North-Mini-Code-1.0-GGUF` (imatrix UD; bartowski too) | **UD-IQ3_XXS 10.89 GiB** (experts 9.71 = 0.202 GiB per MoE layer, IQ3_XXS/IQ2_S; dense 0.77; token_embd Q6_K 0.41) · UD-Q2_K_XL 9.76 / UD-IQ2_M 9.19 (pure T-1 with margin) · UD-IQ3_S 11.89 (k≈4–5 → T0) · UD-IQ4_XS 14.18 (k≈16 → T1 ≈ 1.8–2×) · UD-Q4_K_XL 17.93 (k≈34) · Q8_0 30.21 (> 3× ✗) | yes — interleaved reasoning; the fork has the Cohere2-MoE/"North Code" chat parser (`common/chat.cpp:2553`) | **500 000** (`rope_scaling: none`, θ 50 000) | weights 10.89 (incl. the 0.41 GiB `output` copy) + KV q8 **3.45** (13 full layers × 4 × 128) + SWA cache 0.17 + compute ~1.2 ≈ **15.7 GiB ≈ 98 % of 16.0** — exactly the wanted tight fit, zero margin: if it OOMs, `--n-cpu-moe 1` (15.5) or `2` (15.3) costs ≈ −6 / −12 % (a CPU MoE layer reads 8/128 × 0.202 GiB = 12.6 MiB/token ≈ 0.6 ms incl. sync) and is still T0-class; UD-Q2_K_XL → 14.6 GiB (91 %) is the pure-T-1 fallback | ~0.5 GiB (token_embd) | ~1.8 GiB read/token (0.77 dense + 0.41 output + 0.61 experts) → **~100–130 t/s** all-GPU, 3–4× the dense 9B; no MTP; pp fast (3B active) | **SWE-V 67.6, LCB-v6 70.3, TB2 36.0** (TB-Hard 31.1, SWE-Pro 40.2; Cohere's chart, transcribed; bf16) — between Qwen3.5-9B (LCB 65.6, no SWE-V) and Qwen3.6-35B-A3B (73.4 / 80.4 / 51.5) | **the only coding-specialised thinking model that fits entirely in 16 GiB at 262K**, and the fastest. Risks: 3-bit experts (loss unmeasured — compare with the 9B Q8_0 on real tasks), arch only 3 months old in llama.cpp, benchmarks come from an image, 98 % fill may OOM on compute buffers (then k=1–2) |
| T-1 safe | **Qwen3.5-9B** (dense hybrid GDN 24+8 full-attn, 4 KV × 256) — `unsloth/Qwen3.5-9B-MTP-GGUF` (no 3.6/3.8-9B exists) | **Q8_0 9.11 GiB** (default — largest that fits; UD-Q8_K_XL 12.34 does not) · UD-Q6_K_XL 8.37 only if Q8 OOMs on compute buffers | yes (default; `enable_thinking:false` to disable) | 262 144 | **everything on the Quadro**: weights 9.11 + KV q8 **4.25** + GDN state 0.05 + compute ~1.2 ≈ **14.6 GiB ≈ 94 % of VRAM** — the wanted tight fit | ~1 GiB (token_embd stays on CPU by default) | **30–35 t/s** raw (dense, memory-bound on 448 GB/s); ×1.6–1.9 with `draft-mtp` → 50–65 t/s; pp ≈ 1 k t/s short, GDN-prefill caveat at 100K+ | LCB-v6 **65.6** (= Qwen3-30B-A3B-Thinking-2507 66.0; T0/T1 80.4, gpt-oss-20b 74.6), BFCL-V4 66.1, TAU2 79.1, LongBench-v2 55.2; **no SWE-V on the card** | the *safe* T-1: dense Q8_0 (no quant risk), MTP head, 6 % margin; 3–4× slower than North and weaker on paper (LCB 65.6 vs 70.3, no SWE-V) — the reference North must beat on real tasks. Same `qwen35` arch/rules as T0/T1 (never `--no-kv-offload`, never `-b 512`). Fill the last ~0.9 GiB by raising `-ub` for pp, not by KV f16 (K f16 alone = +4 GiB) |
| T-1 alt | **Gemma-4-26B-A4B-it** (Google, 2026-03-11; `gemma4`: 30 layers = 5 full (kv 2 × 512, K==V stored twice) + 25 SWA-1024 (kv 8 × 256), 128 experts top-8 + shared MLP, tied embeddings, MTP drafter) — `unsloth/gemma-4-26B-A4B-it-GGUF` | UD-IQ3_S 10.63 / UD-IQ3_XXS 10.51 (all-VRAM 14.7 / 14.5 GiB incl. the 0.56 GiB output copy) · UD-Q3_K_M 11.84 → 15.9 (k=1–2) · UD-IQ4_XS 12.65 → k≈4 (T0) · UD-Q4_K_XL 15.83 → k≈10 (T1 ≈ 1.9×) · Q8_0 25.0 (> 3× ✗). `moe_intermediate 704` (not ×256) → expert down-proj falls back to IQ4_NL/Q5_1 in every i-quant (good for quality, sets the size floor) | `<|think|>` via chat template | 262 144 | KV q8 2.66 + SWA 0.16 + compute 1.2 | ~0.6 | ~100–115 t/s (4B active) | **LCB-v6 77.1**, Tau2 68.2 (Google card); SWE-V 57.4 / TB2.1 37.2 (NVIDIA's harness) | best *generalist* that fits all-VRAM: beats North on LCB, clearly loses on SWE-V; not coding-specialised → second choice. **Run without the MTP drafter on Vulkan** (#24664/#28188/#27460 crashes) |
| T-1b | Qwen3.6-35B-A3B fully in VRAM (test-only) — MTP repo `unsloth/Qwen3.6-35B-A3B-MTP-GGUF` or non-MTP `unsloth/Qwen3.6-35B-A3B-GGUF`; coding fine-tune `bartowski/Kwaipilot_KAT-Coder-V2.5-Dev-GGUF` (no MTP, imatrix) | **UD-IQ2_M 11.07 (MTP) / 10.73 (non-MTP)**, UD-Q2_K_XL 11.45 (non-MTP), KAT IQ2_M 11.24 — all 2-bit experts | yes | 262 144 | + KV 2.66 + state 0.06 + compute 1.2 → **15.0 / 14.65 / 15.37 / 15.16 GiB (97 / 94.5 / 99 / 98 %)** — OOM risk on compute buffers for the 99 % one | ~1 GiB | 60–130 t/s raw all-GPU (bandwidth model says ~130, Turing-Vulkan reality lower); MTP file ×1.6–1.9 on top | T1 minus an unknown 2-bit loss (KAT: SWE-V 69.4 on its harness, see T0 row) | the only way to get a 35B-A3B *entirely* into 16 GiB; measure quality against T0 once, keep only if the 2-bit loss is invisible on real tasks (unlikely) |
| **T0** | **Qwen3.6-35B-A3B "cold experts in RAM ≤ 30 %"** — non-MTP `unsloth/Qwen3.6-35B-A3B-GGUF` for the tightest fit, MTP repo when the extra layers still fit the rule | **non-MTP UD-IQ3_S 12.74 GiB** (≈ 0.28 GiB/expert-layer) · non-MTP UD-IQ3_XXS 12.30 (0.256/L) · MTP UD-IQ3_XXS 13.10 (0.27/L; the MTP head costs 0.3–1.6 GiB depending on quant: IQ3_S 14.29 vs 12.74!) | yes | 262 144 | budget for experts ≈ 15.5 − 1.2 − 2.66 − 0.06 − non-expert weights (1.5–1.9) ≈ **9.7–10 GiB** → non-MTP IQ3_S: 35 of 40 layers in VRAM → **`--n-cpu-moe 5`**; non-MTP IQ3_XXS: **`--n-cpu-moe 3`**; MTP IQ3_XXS: **`--n-cpu-moe 7`**. Start one layer higher than the arithmetic, lower until OOM (fill VRAM) | 1–2.2 GiB | per token the CPU reads k × (GiB/L)/32 (+ k host syncs ≈ 0.2 ms each): k=3 ≈ +1.4 ms (**−10–15 %**), k=5 ≈ +2.4 ms (**−15–25 %**), k=7 ≈ +3.5 ms (−25–45 %, depends on the all-GPU base: 7.5–11 ms/token) → 50–110 t/s raw; MTP file adds ×1.6–1.9 on thinking/code output | as T1 minus the 3-bit loss (Qwen card: SWE-V 73.4, LCB-v6 80.4, TB2 51.5; KAT's harness puts the base at SWE-V 64.4) | MoE experts are *per-token sparse* (8 of 256): k CPU layers cost ≈ k/32 of their bytes per token, so ≤ 8 layers ≈ ≤ 30 %, 20 layers ≈ 2× (config A), 40 ≈ 3–4× (config B). Pick: **non-MTP UD-IQ3_S `--n-cpu-moe 5`** (best quant that respects the rule with margin) vs **MTP UD-IQ3_XXS `--n-cpu-moe 7`** (rule edge, but ×1.6–1.9 from draft-mtp on the long thinking traces where ngram does not help) — measure both |
| T0b | **KAT-Coder-V2.5-Dev** (Kwaipilot, 2026-07-23) = Qwen3.6-35B-A3B **fine-tuned for agentic coding**, thinking kept (`enable_thinking`, `preserve_thinking`), no MTP head — `bartowski/Kwaipilot_KAT-Coder-V2.5-Dev-GGUF` (imatrix, b10087) | IQ3_XXS 13.85 (0.31/L) → `--n-cpu-moe 8` · IQ3_M 15.74 → ~14 · IQ4_XS 17.51 → ~16 · Q4_K_M 19.92 → ~20 · Q6_K 27.99 → ~27 | yes | 262 144 | same geometry as T0 (KV 2.66) | 2.5–20 GiB | IQ3_XXS k=8 ≈ −30–45 % (T0 edge); Q4_K_M k=20 ≈ 2× and Q6_K k=27 ≈ 2.9× (T1) | **SWE-V 69.4, SWE-Multilingual 63.0, SWE-Pro 46.0, TB-2.1 41.0** — on KAT's own harness where the Qwen3.6-35B-A3B base scores 64.4 SWE-V, i.e. **+5 over base** | the only *coding-specialised* thinking model in the 35B-A3B class — the literal reading of the requirement. Costs: no MTP (−40 % effective tg vs the MTP Qwen file), bartowski IQ quants instead of unsloth UD. Run it head-to-head with T0 on 3–5 real repo tasks before choosing |
| — | gpt-oss-20b (`gpt-oss`, 24 layers = 12 full + 12 SWA-128, 32 experts top-4, attention sinks) — `ggml-org/gpt-oss-20b-GGUF` | MXFP4 **11.28 GiB** (= 12.1 GB — the earlier "16.6 GiB" mixed GB and GiB) | `reasoning_effort` low/med/high | **131 072** = YaRN ×32 from 4 096 already; 262K needs `--rope-scale 64 --yarn-orig-ctx 4096` | 12 full-attn × 8 KV × 64: KV q8 **3.19** @262K + weights 10.71 (untied, token_embd on CPU) + compute 1.2 ≈ **15.1 GiB — fits (94 %)** | 0.6 | ~90 t/s | LCB-v6 74.6 / SWE-V 60.7 (Qwen's table; 52.4 on NVIDIA's), **TB2.1 15.2** | fits after all, but 256K only by doubling an already ×32 YaRN (quality unverified) and weak agentic (TB 15) → T0(i) fallback at best, dominated by North and T0 |
| **T1** | **Qwen3.6-35B-A3B** — `unsloth/Qwen3.6-35B-A3B-MTP-GGUF` | UD-Q4_K_XL 21.3 GiB (speed) · Q8_0 35.2 / UD-Q6_K_XL ~27.8 (quality) | yes (default; `preserve_thinking` opt-in) | 262 144 | rest 2.5 + KV 2.66 + state 0.06 ≈ 5.3 GiB → **~9 GiB spare = 18–20 of 40 expert layers @ Q4** (0.46 GiB/layer; Q8: 11 layers @ 0.77) | 9–18 GiB | 10–20 t/s (×1.5–2.5 with draft-mtp+ngram-mod) | SWE-V **73.4**, TB2 51.5, LCB-v6 80.4, TAU3 67.2 | best score/speed ratio of everything that fits; `qwen35moe` mature (b7990), MTP head embedded (b9180+, ~75 % acceptance, >2×). Vulkan: never `--no-kv-offload` (#24519 gibberish), never `-b 512` (#27237), watch decode collapse #26795 (AMD-only so far) |
| **T2** | **Qwen3.8-Flash-Next** (125B-A6B + 51B n-gram table + MTP) — `unsloth/Qwen3.8-Flash-Next-GGUF` | **UD-IQ4_XS 87.3 GiB** (UD-Q4_K_XL 103.7 is too tight for 128 GiB) | yes; `reasoning_effort` xhigh/medium/low, `preserve_thinking` default on | 262 144 | rest 5.1 + KV 3.19 + QSA indexer-K 0.75 + state 0.11 ≈ 9.2 GiB (experts all on CPU) | experts ~60 + n-gram table ~27 (host-side `get_rows`, stays in RAM) ≈ **87 GiB** → ARC cap ≤ 8 GiB, no dockaws VM | 4–7 t/s (+MTP only with unsloth fork / PR #28243 — the remote node already runs a patched build) | SWE-Pro **62.5**, DeepSWE 58.7, LCB-v6 **91.9**, Toolathlon 73.5 | the quality stretch; the model already proven on the remote CPU node (`remote/serve-new.sh`). Needs llama.cpp **≥ b10889** (master; v0.4.0 has qwen4exp base but not #27880/#27941/#28023/#28123/#28330). Vulkan sparse-FA for QSA still open (#28105); open Vulkan bugs #27431/#28158/#28280 |
| T3 | Qwen3.5-122B-A10B — `unsloth/Qwen3.5-122B-A10B-MTP-GGUF` | UD-Q4_K_XL 73.3 GiB (UD-IQ4_XS 57.7) | yes | 262 144 | rest 6.2 + KV 3.19 + 0.15 ≈ 9.6 GiB | 65 GiB | 3–5 t/s | SWE-V 72.0, TB2 49.4, LCB 78.9 | **dominated by T1 on paper** (lower scores, 3× slower); only if T1 quality disappoints and T2 is unusable on Vulkan |
| T4 | Nemotron-3-Super-120B-A12B (`NEMOTRON_H_MOE`, MTP) | Q4 ≈ 59 GiB experts | yes | 256K (8 attn layers → KV q8 @256K only 1.06 GiB) | ~6 GiB | ~60 GiB | 3–5 t/s | SWE-V ≈ 60 | non-Qwen fallback family if Qwen hybrids misbehave on NVIDIA Vulkan; Mamba-SSM Vulkan perf concern #23348 |
| T5 | Step-3.7-Flash 196B-A11B | Q4/IQ4_XS ≈ 100–106 GiB experts | yes | 128K native, 256K via RoPE ×2 | ~9 GiB (KV 6.4) | >100 GiB | 3–5 t/s | SWE-V 74.4, TB2.1 59.5 | does not fit 128 GiB at Q4 with headroom; 256K not native → conditional, unlikely |

Rejected (one line each): Qwen3.6-27B / Qwen3.8-27B dense (SWE-V 77.2 / TB2.1
73.0 but 16.4 GiB weights + 8.5 GiB KV q8 @262K > 16 GiB; `--n-cpu-ffn` of a
dense FFN on DDR4 ≈ 3–4 t/s), Qwen3-Coder-Next & Qwen3-Coder-30B (non-thinking),
Qwen3-30B-A3B-Thinking-2507 (48 full-attn layers → KV 12.75 GiB q8),
Qwen3.5-397B-A17B (228 GiB Q4), Qwen3.8-2.4T (API scale), GLM-4.7-Flash /
MiniMax M2.x (< 256K), GLM-5.3-Flash & DeepSeek V4-Flash (not mainline / too
big), gpt-oss (128K), Devstral-2 (dense), Kimi K2/K3 & Ornith-1.5-397B (too big
for one box — Ornith is what the 3-node RPC POC serves), Nemotron-Labs-3-Puzzle
(SWE 56.9, GGUF unverified), **Nemotron-3.5-Lightning-30B-A3B** (SWE-V 51.6
< T0/T1 *and* no fully-in-VRAM file exists: `moe_intermediate 1856` is not a
multiple of 256, so every i-quant falls back to k-quants for the experts —
`unsloth/…-GGUF` is 18.09 GiB even at IQ1_M, ggml-org Q4_0 17.60; with
offload it would only be a worse T0), Ling-3.0-flash (tool-call parser PR
#28682 still open).

From the two wide sweeps (`research/sweep-cn.md`, `research/sweep-west.md`):
**Nemotron-Cascade-2-30B-A3B** (LCB **87.2** — best in class — but SWE-V 50.2 /
TB2.0 21.1 and the same 16.9 GiB k-quant expert floor as Lightning → T1 only at
≈ 1.7×; the pure-algorithmic alternative if LCB is what matters),
Nemotron-3-Nano-30B-A3B (SWE-V 34–39, same floor), Gemma-4-31B (KV 10.6 GiB),
Gemma-4-12B (dense; Q8_0 fits at ~15.4 GiB incl. the tied output copy, LCB 72.0,
no SWE/TB, ~25 t/s — only if both T-1 picks disappoint), Gemma-4-E2B/E4B,
Nemotron Nano 4B/9B/12B and Nemotron-H-8B (no SWE/TB, 128K), Falcon-H1R-7B
(TB-Hard 4.9), Jamba-Reasoning-3B (Mamba-1 scan has no Vulkan kernel),
Trinity-Mini (131K, no coding evals), Granite-4.2-3b (131K, KV 10.6 GiB),
LFM2.5-8B-A1B (128 000 ctx, "not for heavy programming"), Ministral-3-Reasoning
/ Magistral / Devstral-2 (dense, KV 14–21 GiB @262K), Phi-4-mini-flash (no
llama.cpp arch), Olmo-3 (65K), EXAONE-4.x / Hermes-4 / Apriel / ZAYA1 / Motif /
rnj-1.5 (arch, context or no thinking). CN side: Qwen3.5-35B-A3B (SWE-V 69.2,
same size as the 3.6 file — no reason), Qwen3.5-4B (Q8_0 ≈ 14.3 GiB all-VRAM,
LCB 55.8 / SWE-V 33.6 — a weaker T-1), Ling-3.0-tiny (7.9B-A1.3B KDA+MLA,
131K + YaRN, Q8_0 7.8 GiB, TB2.1 27.7, arch `bailingmoe3` is in the fork, but
MLA long-context FA bug #28124), GLM-4.7-Flash (202K native, MLA bug, T1 2×),
ERNIE-4.5-21B-A3B-Thinking (131K + YaRN), Kimi-Linear (no thinking); **no
Qwen3.6/3.7/3.8 model below 27B exists**. Nothing in either sweep beats North
(T-1) or Qwen3.6-35B-A3B / KAT-Coder (T0/T1) on the coding + thinking + 256K +
fits intersection.

**Recommendation (ranked by speed → VRAM fit → requirements):**

| tier | pick | download | fit | expected raw tg | verdict |
|---|---|---|---|---|---|
| **T-1** | **North-Mini-Code-1.0 UD-IQ3_XXS** (`--n-cpu-moe 0`; 1–2 only if it OOMs) | 10.9 GiB | **98 % VRAM (15.7 GiB)**, zero margin | 100–130 t/s | coding-specialised, thinking, 500K native, all-GPU, fastest — verify the 3-bit quality vs the 9B |
| T-1 safe | Qwen3.5-9B **Q8_0** | 9.1 GiB | 94 %, nothing in RAM | 30–35 t/s (50–65 with MTP) | no quant risk, MTP; slower, LCB 65.6, no SWE-V — the reference |
| T-1 alt | Gemma-4-26B-A4B-it **UD-IQ3_S** (no MTP drafter) | 10.6 GiB | 92 % (14.7 GiB) | 100–115 t/s | generalist: LCB 77.1 but SWE-V 57 — if North's quality disappoints |
| T-1b | Qwen3.6-35B-A3B **UD-IQ2_M** (non-MTP 10.73) or KAT-Coder **IQ2_M** 11.24 | 10.7–11.2 GiB | 94–98 % | 60–130 t/s | 2-bit experts: quality unknown, test once |
| **T0** | Qwen3.6-35B-A3B **non-MTP UD-IQ3_S** `--n-cpu-moe 5` (alt: **MTP UD-IQ3_XXS** `--n-cpu-moe 7`) | 12.7 / 13.1 GiB | 15.3–15.5 GiB VRAM + 1.4–1.9 GiB RAM | 60–110 t/s (−15–25 % / −25–45 %; the MTP file wins ×1.6–1.9 back) | **best model within the ≤ 30 % rule**: SWE-V 73.4 / LCB 80.4 class, +6 SWE-V / +10 LCB over North |
| T0b | **KAT-Coder-V2.5-Dev IQ3_XXS** `--n-cpu-moe 8` | 13.9 GiB | 15.4 + 2.5 | −30–45 % | coding fine-tune of T0 (+5 SWE-V on KAT's harness), no MTP — head-to-head with T0 |
| **T1** | Qwen3.6-35B-A3B **UD-Q4_K_XL** `--n-cpu-moe 20`, then **Q8_0** `--n-cpu-moe 29` | 21.3 / 35.2 GiB | ~15.5 VRAM + 9–18 RAM | 2× / 3× slower than all-GPU | the 1.5–3× rule; Q8 = quality reference |
| **T2** | Qwen3.8-Flash-Next **UD-IQ4_XS** | 87.3 GiB | 9 GiB VRAM + 87 GiB RAM, ARC ≤ 8 GiB, no VM | 4–7 t/s | the only candidate clearly *better* than T1; master build ≥ b10889 |

Order of work: **T-1 first — North-Mini-Code UD-IQ3_XXS (10.9 GiB)**: proves the
Vulkan/NVIDIA/FreeBSD path on a MoE and gives the all-GPU reference; then the
**9B Q8_0** (9.1 GiB, dense + MTP reference) and a 3–5 task head-to-head; then
**T0** (+ T0b KAT-Coder, same class), then **T1** Q4 → Q8_0, then T2 on a master
build. Skip T-1 alt / T-1b / T3–T5 unless the ones above fail.

What each hard requirement is worth in 16 GiB: *coding-specialised* is now
satisfied literally (North in T-1, KAT-Coder in T0b) — the generalists
(Gemma-4-26B, Cascade-2) only win on LCB; dropping *fully-in-VRAM* (≤ 30 %
RAM) → T0 (SWE-V 73 class) is still by far the best trade; dropping *256K →
128K native* buys only gpt-oss-20b (fits at 15.1 GiB, LCB 74.6 but TB 15),
Trinity-Mini and Granite-4.2-3b — none better than T0; dropping *thinking*
buys nothing (Qwen3-Coder-30B and Devstral-Small-2 carry 12–21 GiB of KV at
256K).

## 5. Configurations to test

Common (all from readme.md laws + research): `--ctx-size 262144 --parallel 1
--gpu-layers 99 --fit off --flash-attn on --cache-type-k q8_0 --cache-type-v
q8_0 --batch-size 2048 --ubatch-size 1024 --threads 8 --threads-batch 16
--load-mode none --ctx-checkpoints 8 --jinja --reasoning on
--reasoning-format auto --spec-type draft-mtp,ngram-mod --spec-draft-n-max 6
--spec-draft-p-min 0.75 --device Vulkan0` (+ sampling per model card; Qwen3.6
thinking: temp 1.0 / top-p 0.95 / top-k 20 / min-p 0 — re-check card at
download time). `--fit off` matters: `auto` fit would otherwise re-place
experts itself. **`draft-mtp` only for files with an MTP head** (the
`*-MTP-GGUF` Qwen repos): on a model without `nextn` layers llama-server
refuses to start (`context type MTP requested but model doesn't contain MTP
layers` → `failed to create MTP context`, `server-context.cpp:1140`), so
North-Mini-Code, KAT-Coder, Gemma 4 and the non-MTP Qwen files run with
`--spec-type ngram-mod` alone.

- **T-1 (North UD-IQ3_XXS):** common set, `--n-cpu-moe 0`; on OOM at
  load or on the first 262K prompt → `--n-cpu-moe 1`, then `2` (§4). Fill
  any leftover with `-ub` for pp. `--cache-ram` default is safe (544
  B/token per K or V, §6 rule 2).
- **T-1 safe (Qwen3.5-9B Q8_0):** common set incl. `draft-mtp`, plus
  `--cache-ram 0` (§6 rule 2).
- **T0 / T0b:** common set with `--n-cpu-moe 5` (non-MTP UD-IQ3_S) / `7`
  (MTP UD-IQ3_XXS) / `8` (KAT IQ3_XXS); lower until OOM, then +1.

- **A — max-VRAM reference (T1):** `--n-cpu-moe 20` (layers 0–19 experts on
  CPU, 20–39 on GPU, Q4). Lower N until OOM; Q8: start `--n-cpu-moe 29`. This
  is the "VRAM-only-ish" baseline for the ≤1.5–3× rule.
- **B — all experts in RAM (T1 first, then T2/T3):** `--cpu-moe` (≡
  `--n-cpu-moe 40`). B/A ratio = the real cost of RAM experts on this box.
  Variants: `-t 8` vs `-t 12`; epp 100 vs 0 (`sysctl dev.hwpstate_intel.N.epp`
  for N in 0..15, revert after). (`--load-mode mmap` is **not** a variant here — §6 pinned cap.)
- **C — iGPU split (one shot):** `GGML_VK_VISIBLE_DEVICES=0,1 --device
  Vulkan0,Vulkan1` with `-ot 'blk\.(3[0-9])\.ffn_.*_exps=Vulkan1'` (10 expert
  layers on the P630 instead of CPU). Expected slower than B; record and drop.
- **D — GDN on CPU (mitigation, if pp at 32K+ is slow):** Vulkan
  GATED_DELTA_NET prefill is the sequential kernel (chunked #20377 still
  draft) → try `-ot 'blk\..*\.(ssm_|attn_gate|linear_attn).*=CPU'` (exact
  tensor names via `gguf-dump` at test time).
- **Never:** `--no-kv-offload` on Vulkan with qwen35* (#24519); `-ub 2048`
  (tuxi DeviceLost); `-b 512` (#27237); `llama-bench` with GPU-resident
  weights until it is proven not to hang this box (readme.md rule).

## 6. Build (2026-09-11, native, in place)

Same recipe as tuxi (`bin/01b-build-vulkan.sh` in `/data/ai/local-agent-poc`),
rebuilt **in place** on asgard because the synced `build-vulkan/` held tuxi's
Zen4 `-march=native` binaries (SIGILL here; `build-cpu/` is still tuxi's and
unused). Run as the ordinary user:

    cd /data/ai/local-agent-poc && BUILD_TESTS=ON bin/01b-build-vulkan.sh
    # = cmake -S src/llama.cpp -B src/llama.cpp/build-vulkan -G Ninja -DCMAKE_BUILD_TYPE=Release
    #   -DGGML_NATIVE=ON -DGGML_VULKAN=ON -DGGML_OPENMP=OFF -DLLAMA_OPENSSL=ON
    #   -DLLAMA_BUILD_TESTS=ON -DLLAMA_BUILD_UI=OFF -DLLAMA_USE_PREBUILT_UI=OFF
    #   -DCMAKE_PREFIX_PATH=opt/spirv-headers -DCMAKE_CXX_FLAGS=-Iopt/spirv-headers/include
    #   [-DCMAKE_CXX_COMPILER_LAUNCHER=bin/cxx-launcher.sh   # only when cc >= 21]
    # + cmake --build … --target llama-server llama-bench test-backend-ops
    # llama.cpp tag v0.4.0 (5266f24); SPIRV-Headers vulkan-sdk-1.4.357.0 vendored in opt/;
    # clang 21.1.8 (base), glslc 2026.3, cmake 3.31, ninja; BUILD_JOBS from config/poc.env (6, tuxi's value).

**clang 21 trap (asgard-specific, found the hard way):** FreeBSD 15.1-STABLE
ships clang 21.1.8; at `-O3` it needs > 40 min for one translation unit,
`ggml/src/ggml-vulkan/ggml-vulkan.cpp` (register allocation —
`LiveIntervals::extendSegmentsToUses` — blows up on the giant
`ggml_vk_load_shaders`). tuxi's clang 19.1.7 does the same file in 127 s.
Killed after 42 min; measured on asgard: `-O2` 151 s, `-O1` 111 s. Fix:
`bin/cxx-launcher.sh` (CMAKE_CXX_COMPILER_LAUNCHER, enabled by
`01b-build-vulkan.sh` only when `cc -dumpversion` ≥ 21) rewrites `-O3`→`-O2`
for that single TU — host-side Vulkan glue, shader math unaffected; the rest
of the tree stays `-O3`. Both scripts live in the POC `bin/` on both laptops.
Build log: `/var/tmp/llama-build-vulkan2.log`; manifest
`logs/build-manifest-vulkan.txt`.

**Decision (Łukasz, 2026-09-11): keep base clang 21 + the launcher, do not
install `llvm19`.** The regression is compile-time only, in one host-side TU;
clang 21's generated code is equal or slightly better than 19's, and `-O2` on
the Vulkan glue cannot slow inference (the math runs in SPIR-V shaders built
by glslc at build time and by the NVIDIA driver at load time; ggml-cpu stays
`-O3 -march=native`). Log: `/var/tmp/llama-build-vulkan2.log`; manifest
`logs/build-manifest-vulkan.txt`.

**Build result (2026-09-11 19:06 CEST): `BUILD_RC=0`**, 486 ninja steps,
≈ 2 h wall including the aborted first attempt (clean rebuild with the
launcher ≈ 25 min at 6 jobs, epp=0); `ggml-vulkan.cpp.o` 152 s at `-O2`.
Binaries in `build-vulkan/bin/`: `llama-server`, `llama-bench`,
`test-backend-ops`, `libllama.so`, `libggml*.so`, `libmtmd.so`;
`llama-server --version` → `0.4.0-dev (build 1, commit 5266f24), built with
Clang 21.1.8 for FreeBSD amd64`.

The `/data/local-ai/llama` launcher (RUNPATH → this `build-vulkan/bin`) is
therefore valid on asgard too. `pkg install spirv-headers` (1.4.357.0) is the
alternative to the vendored prefix.

For T2 a **master** build is required: `git -C .../llama.cpp fetch --tags`,
`git worktree add ../llama.cpp-master <tag ≥ b10889>`, same cmake into
`build-vulkan-master` (keep v0.4.0 untouched for the POC docs).

**FreeBSD nvidia pinned-memory cap (found by §7 step 2, 2026-09-11):**
nvidia 595.99.02 on FreeBSD refuses any single **host-visible** Vulkan
allocation ≥ 256 MiB: measured with a 40-line probe (`asgard/vkalloc.c`) — 255 MiB OK, 256 MiB
`VK_ERROR_OUT_OF_DEVICE_MEMORY`, identical for memory types 2/3 (heap 1 =
95.7 GiB system RAM, HOST_VISIBLE|COHERENT[|CACHED]) and type 4 (BAR heap,
246 MiB; `EnableResizableBar=0`). The *total* is not capped (765 × 128 MiB =
95.6 GiB pinned fine, freed cleanly) and **device-local allocations are fine**
(8 GiB tested). ggml-vulkan uploads/downloads through one staging buffer sized
to the copy (`ggml_vk_ensure_sync_staging_buffer`), so any single
`tensor_set/get` ≥ 256 MiB aborts the process
(`ggml_uncaught_exception` → SIGABRT). Rules that follow:

1. **`--load-mode none` is mandatory** on asgard. The default `auto` = mmap on
   a dGPU, and the mmap path uploads every GPU tensor whole (`output.weight`
   of Qwen3.5-9B Q8_0 = 1.0 GiB, 35B-A3B Q8_0 expert tensors = 408 MiB →
   abort at load). With `none` the loader streams through 4 pinned buffers of
   64 MiB (+ alignment) asynchronously (this fork's Vulkan device reports
   `async + host_buffer + events`). Also never `--check-tensors` (disables
   the async path) and never `GGML_VK_PREFER_HOST_MEMORY`.
2. **Server prompt cache / slot save read KV back the same way**
   (`--cache-ram`, default 8192 MiB; `--slot-save-path`): per layer, per
   contiguous cell range. Qwen3.5-9B K or V per layer = 4 × 256 × 1.0625 B =
   1088 B/token → a saved range > ~246 K tokens is > 255 MiB → **`--cache-ram 0`
   for the 9B** (35B-A3B, Flash-Next and North-Mini-Code: 544 B/token = 136
   MiB @ 262 144 — safe; Gemma-4-26B/12B global layers 2 × 512 → 1088 B/token
   → `--cache-ram 0` as well). `--ctx-checkpoints` only copies the small
   recurrent state — fine.
3. Scheduler CPU↔GPU activation copies (`--n-cpu-moe`) are ≤ 32 MiB at
   `-b 2048` — fine. KV cache and compute buffers are device-local — fine.
4. `test-backend-ops` full run aborts at `MUL_MAT_ID_FUSION(f32, 128 experts,
   768×2048)` (768 MiB upload) — the driver cap, not a kernel bug; run with
   `-o` lists (§7 step 2).
5. S3 (`zzz`) with a request in flight: tested 2026-09-12 07:26 — the process
   survives, the pending Vulkan fence never signals (TERM-immune hang, VRAM
   held). Contract (`ops.md`): the owner stops/starts around a manual `z`;
   the thermal watchdog's suspend action runs `unstick.sh pre-suspend` /
   `post-resume` (stop first, restart after if it was running); `unstick.sh
   fix|watch` is the stall detector the E2E harness runs. Idle-server VRAM
   survival across S3 is still untested.
6. Possible permanent fix (not done): make `ggml_vk_buffer_write_2d/read` in
   `ggml/src/ggml-vulkan/ggml-vulkan.cpp` loop over ≤ 128 MiB staging chunks
   (≈ 20 lines) — would retire rules 1–2 and make `mmap` loads work again;
   worth a POC-fork patch once a model runs, so the fix can be measured.

## 7. Test protocol (server-only, one client at a time)

1. `build-vulkan/bin/llama-server --list-devices` → expect Vulkan0 = Quadro
   (16 GiB), Vulkan1 = P630. Set `GGML_VK_VISIBLE_DEVICES=0` for A/B/D.
   **Done 2026-09-11:** `Vulkan0: Quadro RTX 5000 (16630 MiB, 16344 MiB
   free)`, `Vulkan1: Intel(R) UHD Graphics P630 (CML GT2) (97995 MiB, 29491
   MiB free)`. Drivers: NVIDIA 595.99.2.0 / Vulkan 1.4.329, Intel ANV 26.2.2 /
   1.4.354. ggml sees the Quadro as `uma: 0 | fp16: 1 | bf16: 1 | fp4: 0 |
   warp size: 32 | shared memory: 49152 | int dot: 1 | matrix cores:
   NV_coopmat2` — the fast path (coopmat2) is available, no env fallbacks needed.
2. `timeout 900 build-vulkan/bin/test-backend-ops -b Vulkan0` — the gate for
   issue **#15996 "Vulkan backend hangs forever with NVIDIA GPU on FreeBSD"**.
   If it hangs: retry with `-o MUL_MAT`, then `GGML_VK_DISABLE_COOPMAT2=1`,
   `GGML_VK_DISABLE_COOPMAT=1`, `GGML_VK_DISABLE_F16=1`; if still dead, the
   whole plan degrades to CPU-only (then T1 Q4 ≈ 8–14 t/s is the ceiling).
   **Done 2026-09-11 — passed, 0 FAIL in ≈ 19 200 cases** (excerpt:
   `research/test-backend-ops-2026-09-11.txt`). (a) Unrestricted run: 9 054
   OK / 0 FAIL / 2 523 not-supported, then SIGABRT (rc 134) after 15 min at
   `MUL_MAT_ID_FUSION(type_a=f32, n_mats=128, m=768, k=2048)` — a 768 MiB
   staging upload → `vk::Device::allocateMemory: ErrorOutOfDeviceMemory` in
   `ggml_vk_ensure_sync_staging_buffer` = the driver pinned cap (§6), **not**
   the #15996 hang. (b) `-o MUL_MAT_ID`: 883/883. (c) all 111 op names from
   `test-backend-ops support -b Vulkan0`: **16 214/16 214, 19 min**. (d) the
   23 fused/whole-graph tests (`ADD_ADD … TOPK_QSA, SIGMOID_MUL, SILU_MUL,
   SOFTPLUS_MUL`): **2 153/2 153**. (e) `-o MUL_MAT_ID_FUSION -p 'type_a=q4…'`:
   6/6 — the 216 MiB q4_0/q4_K uploads of the same shape pass, only the
   f32/f16 (768/384 MiB) cases exceed the cap. No env fallback
   (`GGML_VK_DISABLE_*`) was needed; coopmat2 path active throughout.
3. Dataset — **done 2026-09-11**: `zroot/data/local-ai` (compression=off,
   primarycache=metadata, recordsize inherited 128K like tuxi); models go to
   `/data/local-ai/models/`. Cap ARC for T2:
   `sysctl vfs.zfs.arc.max=$((8<<30))`.
4. Downloads (Wi-Fi only, ~10 MB/s; `sha256` each): **T-1**
   `unsloth/North-Mini-Code-1.0-GGUF/North-Mini-Code-1.0-UD-IQ3_XXS.gguf`
   (10.9 GiB ≈ 19 min) first → serve all-GPU (`--n-cpu-moe 0`, `ngram-mod`
   only); `health.sh`-style round-trip; then the 256K warm-up prompt (tuxi
   law 3 — DeviceLost check) — this is also where a 98 % fill shows OOM →
   `--n-cpu-moe 1–2`. Then **T-1 safe** `unsloth/Qwen3.5-9B-MTP-GGUF`
   `Q8_0` (9.1 GiB ≈ 15 min, `draft-mtp`, `--cache-ram 0`) and the 3–5 task
   head-to-head. Then **T0** `unsloth/Qwen3.6-35B-A3B-GGUF/UD-IQ3_S`
   (12.7 GiB) — alt `…-MTP-GGUF/UD-IQ3_XXS` (13.1) — and **T1**
   `unsloth/Qwen3.6-35B-A3B-MTP-GGUF/UD-Q4_K_XL` (21.3 GiB ≈ 40 min). Serve
   T1 as config A.
5. Grid (each ≥ 3 runs, server `/metrics` + `--verbose` timings): pp at
   0/32K/128K prompt (GDN prefill cost!), tg at 0/20K/100K depth, MTP+ngram
   acceptance on a real agent turn, `nvidia-smi` VRAM, RSS, PCH/CPU/GPU °C.
   Order: A(Q4) → B(Q4) → epp/threads variants → C once → D only if pp is bad
   → A/B at Q8_0.
6. T2 (optional — owner decides at the end, see §1): master build → `UD-IQ4_XS` (87 GiB ≈ 2.5 h at 10 MB/s) → B only
   (+ `--reasoning-effort medium`), same grid; MTP only after porting the
   remote node's qwen4exp patch or unsloth's fork.
7. Pick: highest score whose tg@20K ≥ ⅓ of the A(Q4) result and ≥ 8 t/s raw;
   write the winner into a new `serve-asgard.sh` + readme.md.

Success bar (from tuxi experience): pp ≥ 100 t/s, tg ≥ 8 t/s raw at 20K
depth, no DeviceLost across a 256K warm-up, ≥ 70 % speculative acceptance on
edit-heavy turns.

## 8. Risks / open questions

- **#15996** Vulkan+NVIDIA+FreeBSD hang — unverified on Turing; step 2 decides.
- **S3 hang** (2026-09-12): handled — §1 power row / §6 rule 5 / `ops.md`; the
  residual cost is the in-flight request plus a re-ingest of the session.
- **02:09 hard freeze** (2026-09-12, GPU 89 % + turbo 4.7 GHz, new request at
  113K ctx): cause unknown, no dump path (no swap); netdump over `em0` or the
  BIOS event log are the owner's options (results-t1.md).
- **GDN prefill on Vulkan is sequential** — could make 100K+ prompts crawl for
  every Qwen3.5+/Flash-Next hybrid; mitigation D.
- **CPU clocks**: Turbo is off in BIOS → 2.4 GHz ceiling regardless of epp;
  with the default epp=100 the cores drift to 1.4–1.6 GHz under load. For
  grids set `sysctl dev.hwpstate_intel.{0..15}.epp=0` (runtime only, restore
  to 100 afterwards) → 2.4 GHz sustained; the CPU expert path is then ~1.6×
  faster. Ask Łukasz about enabling Turbo in BIOS (up to 5.3 GHz single /
  ~4 GHz all-core within 45 W PL2) before judging any CPU-offload config.
- **RAM contention**: T2 (87 GiB) + ARC + X leaves no room for the dockaws VM.
- **Model freshness**: Qwen3.8-Flash-Next arch landed 2026-08-27; expect
  breakage and re-builds; keep T1 as the stable daily driver.
- Qwen3.5-122B is on paper worse than Qwen3.6-35B-A3B — confirm before
  spending 73 GiB of Wi-Fi time on it.

## 9. Rules carried over from tuxi (readme.md)

`-t 8` for tg (SMT kills tg); ubatch scales pp only, 2048 = DeviceLost;
ngram self-speculation is a free win (71–74 % acceptance); ONE client at a
time with `--parallel 1`; never run GPU `llama-bench` on a box you cannot
power-cycle remotely (asgard has GELI — a hang means a passphrase at boot);
server-side DeviceLost just kills the server (safe to retry).

## 10. Deliverable — three named serving profiles (owner statement, 2026-09-12 11:14)

The research ends in **one `llamactl.sh`/`service llama` profile per tier**, each = the tier's
*best model* (by the E2E coding tasks) in *its best configuration* (by the sweeps: NP, SPEC,
threads, placement):

| profile | tier | placement rule | **generation-speed goal** (owner, 11:20; output t/s, session aggregate) |
|---|---|---|---|
| `fastest-vram` | T-1 | everything in the Quadro (weights, 256K q8_0 KV, compute); the fastest model that passes the coding tasks | expect **> 12 t/s**, never **< 10**, ideal **15–25 t/s** |
| `fast` | T0 | VRAM first, overflow to the **iGPU (Vulkan1) before CPU RAM** — whichever measures faster; no OOM, no "slow-token" regime | not slower than **6 t/s**, absolute minimum **4**, ideal **≥ 7–10 t/s** |
| `best` | T1 (T2 optional — owner decides at the end; T1 is already at the edge of usability) | as much as fits across VRAM + iGPU + RAM, whichever split is fastest, for the best quality | expect **≥ 1.8 t/s**, absolute low **1 t/s** (below = unusable), ideal **> 3 t/s** |

The goals are **first rough estimates** (owner, 11:24: "we will eventually adjust as research
continues") and *soft recommendations for output tokens only* — input (prompt) speed is recorded but
not a selection criterion. Measured as the aggregate generation rate over a whole E2E coding
session (e.g. qwen9b C task: 14.6 t/s aggregate, 6.8 at 200K, 35 fresh), so a model must clear
the floor at depth, not only at a fresh context.

Reporting rule (owner, 11:52): a task verdict is `PASS` / `FAIL-task` (the model did not accomplish the assignment,
nothing of ours broke) / `FAIL-infra` (llama-server, qwen-code, thermal action, freeze, network — re-run, never counted
against the model); status messages say which one every time.

Order of work: finish T-1 (this file + `results-t1.md`) → STOP → T0 → T1 → T2 only if the owner still wants it at the end; the
per-tier winner and its knobs get frozen into `models.sh`/`serve.sh` defaults and documented in
`ops.md`. Speed factors recorded per model (from the E2E logs, not synthetic): incremental prompt
t/s at depth, cold re-encode t/s (session resume / context compaction re-reads the whole history),
generation t/s fresh vs at 100K/200K, and the compaction cost (qwen-code `autoCompactThreshold`
0.95 → one full re-encode of ~200K tokens ≈ 20 min on qwen9b).
