# asgard-deployment — the frozen local-AI service on asgard (daily cheat sheet)

Dell Precision 7750 `asgard` (FreeBSD 15.1, Quadro RTX 5000 16 GiB via Vulkan, 128 GiB RAM): one llama-server at a time on
`http://10.253.254.1:18080` (API key `/data/local-ai/key.secret`), three frozen tiers, started by hand — **nothing starts at boot**.
Research, sweeps and the reasoning behind every number: `/data/local-ai/asgard/` (results-t0/t1/t2.md, STATUS.md).

## Daily commands (on asgard)

| what | command |
|---|---|
| start a tier | `sudo service llama-t0 start` (or `llama-t1` / `llama-t2`) — returns when the server answers and the soft-start ramp is done: t0/t1 ≈ 40 s, t2 ≈ 2 min |
| … with 512K context (YaRN x2) | `sudo service llama-tN start yarn2` (also `restart yarn2`); `start yarn4` is refused — 1M does not fit 16 GiB, see below |
| status / stop / restart | `sudo service llama-tN status` (exit 0 = running, 1 = not) · `stop` (t2 takes ~35 s) · `restart` |
| switch tier | `sudo service llama-t0 stop && sudo service llama-t2 start` — a start refuses while another tier (or the research `start.sh` server) holds the card/port |
| code with it | `qwen.sh` (uses whatever tier runs) · `qwen-t0.sh` / `qwen-t1.sh` / `qwen-t2.sh` (insist on that tier, refuse otherwise) — all in `/data/scripts`; headless: `qwen-t2.sh --yolo -p "…"` |
| raw API | `curl -H "Authorization: Bearer $(cat /data/local-ai/key.secret)" http://10.253.254.1:18080/v1/models` — also `/health`, `/props` (n_ctx), `/slots`, `/v1/chat/completions` |
| logs | `~/local-ai-runs/llama-tN.log` (server log; `.out` = stderr mirror; `.prev` = previous run), `llama-tiers.history` (one line per START/UP/STOP), `llama-tN.pid` |

**From tuxi** (no llama there): the same `qwen.sh` / `qwen-tN.sh` in `/data/scripts` open an ssh tunnel `127.0.0.1:18080 → asgard`
on demand and leave it running (tuxi has its own 10.253.254.1, hence localhost). Start the tier on asgard first:
`ssh asgard sudo service llama-t0 start`.

## The tiers

| tier | service | model (thinking on) | on disk | placement (VRAM) | threads | tg out t/s, GPU healthy → pinned | reasoning effort |
|---|---|---|---|---|---|---|---|
| T0 fastest-vram | `llama-t0` | Qwen3.6-35B-A3B UD-IQ2_M | 10.7 GiB | all in VRAM (14.1 GiB) | 8/16 | 61.5 → 16.0 (never pins) | n/a — Qwen3.6 has thinking on/off only |
| T1 fast | `llama-t1` | Qwen3.6-35B-A3B UD-Q4_K_XL | 20.8 GiB | experts of 20 layers in RAM (15.3 GiB) | 8/16 | 32.5 → 11.0 | n/a |
| T2 best | `llama-t2` | Qwen3.8-Flash-Next UD-IQ4_XS (3 shards) | 87.3 GiB | experts of 47/49 blocks in RAM (14.2 GiB; ~58 GiB RAM + 27 GiB mapped) | 16/16 | ≈4–5 est. → 3.0 | **xhigh** = its maximum (the template accepts only xhigh / medium / low) |

Common: ctx **262 144** (the models' native maximum) × 1 slot, q8_0 KV, flash-attn, `--cache-ram 8192`, batch 2048/1024,
temp 1.0 / top_p 0.95 / top_k 20 / min_p 0 (Qwen thinking-mode card values), reasoning on with unlimited budget.
Served model ids: `qwen3.6-35b-a3b` · `qwen3.6-35b-a3b-q4` · `qwen3.8-flash-next` (+ alias `qwen3coder-local` on all).
"Pinned" = the GPU stuck at 1035 MHz after the EC's power-brake (an AC-adapter event; every T2 load triggers it, a cold reboot
un-pins) — the right-hand speeds are what you get most of the time.

## YaRN (longer context)

| | x2 = 524 288 ctx | x4 = 1 048 576 |
|---|---|---|
| how | `sudo service llama-tN start yarn2` — works on t0, t1 and t2 | refused (`start yarn4`): the 1M KV cache does not fit next to the weights in 16 GiB (~13.6 GiB q8_0 / ~7 GiB q4_0 for T0 alone) and KV in host RAM is not an option on this box |
| what changes | `--rope-scaling yarn --rope-scale 2 --yarn-orig-ctx 262144`; KV cache **q4_0** instead of q8_0 (the doubled KV would not fit at q8_0); t2 also batch 1024/512 (its 512K prefill buffer needs 9.3 GiB at 2048/1024) | — |
| load test 15 Sep | t0: UP 16–18 s, 14.9 GiB VRAM, 16.6 t/s pinned · t1: UP 20 s, **peaks at 16.0 GiB while loading** (15.0 steady — no headroom, prefer t0/t2) · t2: UP 49 s, 11.2 GiB steady, 3.1 t/s pinned — all three answered a test prompt | — |
| caveats | lower KV precision for the whole session; quality beyond 256K is an extrapolation and untested here — use only when a job really needs > 256K | — |

## Install / update

- asgard (root): `sudo /data/local-ai/asgard-deployment/install.sh` — checks binaries, models, key, qwen; installs `rc.d/llama-t{0,1,2}`
  to `/usr/local/etc/rc.d/` (mode 555); symlinks `/data/scripts/qwen*.sh` into this directory. Idempotent — re-run after a pull
  that touched `rc.d/`. Ends with `boot check: 0 of 3 tier scripts would run at boot`.
- tuxi: pull `/data/local-ai`, then `./install-tuxi.sh` (copies `qwen*.sh` to `/data/scripts`; needs the key file, the `qwen` CLI
  and passwordless `ssh asgard`).
- Everything lives in `llama-tier.sh` (tier parameters in `tier_env()`, YaRN in `do_start`) and `qwen.sh`; the rc.d files are stubs.
  Owner commits `/data/local-ai` in git.

## How it is wired / gotchas

- rc.d stubs: `KEYWORD: nostart` → never part of the boot sequence (`rcorder -s nostart`), no shutdown hook; `llama_tN_enable`
  defaults to YES inside the stub, so plain `start`/`stop` work (`onestart` too) and `/etc/rc.conf` needs nothing.
- `llama-tier.sh` drops from root to `lgryglicki`, launches llama-server with `daemon(8)`, waits for `/health` (≤ 30 min), then runs
  a soft-start ramp (7 prompts, 1 → 4096 tokens — the campaign's AC dropouts all sat on the first cold full-power prefill).
  `SOFTSTART=0 ./llama-tier.sh t0 start` skips the ramp (direct call). Stop = TERM, KILL after 30 s (t2 always needs the KILL).
- The research path still exists: `/data/local-ai/asgard/start.sh|stop.sh` (+ the old `/usr/local/etc/rc.d/llama` stub, also
  nostart). Same port → a tier start refuses while it runs: `/data/local-ai/asgard/stop.sh` first.
- `qwen.sh` rewrites `~/.qwen-asgard/.qwen/settings.json` at every run (model id, base URL, ctx from `/props`, sampling, max_tokens
  32768, auto-compaction at 95 %, `report_findings` tool excluded — its schema breaks the grammar converter, 12 h timeouts); the
  real `~/.qwen` is untouched and sessions persist there. Overrides: `QWEN_ASGARD_HOME`, `QWEN_QUIET=1` (no banner),
  `LLAMA_SSH_HOST`, `LLAMA_LOCAL_PORT`, `LLAMA_KEY_FILE`.
- Do not wrap `qwen-tN.sh` in FreeBSD `timeout(1)` on tuxi: `timeout` reaps the background tunnel and waits for it.
- Never: two tiers at once, `nvidia-smi -r/-pl/-lgc`, anything in `/var/tmp`, rebooting while a tier is loading.
