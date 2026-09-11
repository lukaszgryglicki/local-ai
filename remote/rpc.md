# RPC POC — full working path (3-node llama.cpp + qwen from FreeBSD)

Step-by-step to serve one big model split across 3 CPU nodes and use it from the
FreeBSD host with qwen-code. Current production model: **Ornith-1.5-397B Q8_0**
(428.5 GB) — main node holds the GGUF, two helpers hold ~130 GB of tensors each
in RAM.

Topology (private VLAN 10.60.0.0/24):

```
FreeBSD host ──ssh tunnel──> main node (llama-server :18080, 127.0.0.1 only)
                               ├── helper 1  10.60.0.22:50052 (ggml-rpc-server)
                               └── helper 2  10.60.0.32:50052 (ggml-rpc-server)
```

Every file lives under `/data/ai` on the nodes (never the root fs). No disk
caches are used (RPC tensor cache removed 2026-09-08: it saved only ~4 min of
a ~44 min load — the synchronous per-tensor RPC walk is the bottleneck — while
writing ~248 GB to disk). All AI processes are systemd-jailed
(memory-capped, cores 0–43, nice 5) so the nodes' primary tenants always win.

## Step 1 — start the RPC servers on BOTH helper nodes

Order matters: helpers must listen before the main server starts.

Nodes: T2, C2.

On each helper (ssh in as root, use tmux — or the setsid one-liner):

```sh
(setsid nohup /data/ai/start-rpc.sh > /data/ai/rpc.log 2>&1 &)
```

Verify each helper listens on the VLAN:

```sh
ss -tlnp | grep 50052     # expect: LISTEN 10.60.0.x:50052 ggml-rpc-server
```

The scary "Never expose the RPC server to an open network" banner is expected —
that's why it binds the private VLAN IP only.

## Step 2 — start llama-server on the main node (the one with the model)

Node: T1

```sh
(setsid nohup /data/ai/serve-rpc.sh > /data/ai/serve.out 2>&1 &)
tail -f /data/ai/serve.out
```

It autodetects reachable helpers on :50052 (override with `RPC=ip:port,ip:port`)
and refuses to start Ornith unless BOTH are up. Wait for:

```
srv  llama_server: listening on http://127.0.0.1:18080
```

Load time: **~45 min, every start** (streams ~250 GB to helpers over the VLAN).
The load is a synchronous per-tensor walk, single-threaded on both ends
(~110 MB/s ceiling), so the on-disk tensor cache never sped it up meaningfully
— measured, then removed.

Optional local check on the main node:

```sh
curl -s http://127.0.0.1:18080/health          # {"status":"ok"}
```

## Step 3 — start the tunnel on the FreeBSD host

BSD host:

In tmux (it loops and reconnects until Ctrl-C):

```sh
/data/local-ai/tunnel.sh
```

Forwards the remote `127.0.0.1:18080` to `127.0.0.1:18081` on the FreeBSD host
(and `10.253.254.1:18081` for bhyve VMs). The ssh target comes from
`remote-host.secret` (root@main-node), the API key from `remote-key.secret`.

Quick end-to-end check through the tunnel:

```sh
/data/local-ai/health-remote.sh
```

## Step 4 — connect qwen-code from the FreeBSD host

```sh
/data/local-ai/qwen-remote.sh
```

Defaults to the 3-node model (`ornith15-397b`: native 262,144 ctx/slot — YARN=1
server default since 2026-09-09; the overnight run never passed ~53K — temp 0.6,
top-p 0.95, top-k 20, no client-side timeouts). Legacy single-node model instead:

```sh
REMOTE_MODEL=qwen38flash /data/local-ai/qwen-remote.sh
```

Notes: the FIRST request after a server start takes ~1–2 min extra (the main
node pages its ~150 GB of local layers into RAM). Expected steady speed for
Ornith Q8_0: ~24 t/s prompt processing, ~4.5 t/s generation. Server allows 4
parallel requests (slots).

## Unattended / overnight runs — use qwen-super.sh (crash-proof)

Lesson from 2026-09-08: a home↔Linode network flap killed qwen mid-task
(ECONNREFUSED, client `maxRetries` was 1) and the stack idled 5.5 h. The
tunnel self-healed (its retry loop works); the client did not. Three defense
layers now (inner → outer):

1. `qwen-remote.sh` sets `maxRetries: 5000`: the openai SDK itself retries
   connection errors/429/5xx with backoff (caps ~8 s) — qwen keeps RETRYING
   for up to ~11 h instead of dying when the failure happens BETWEEN requests.
2. A failure MID-STREAM still kills the turn → `/data/local-ai/qwen-super.sh`
   relaunches with **real session resume** (`qwen -c`, same as
   `claude/copilot --resume`): chat recording is on by default
   (`general.chatRecording`), sessions live under the qwen HOME
   (`/tmp/remote-ai-qwen-home/.qwen/projects/<cwd>/chats/*.jsonl`), so the
   model gets its full prior conversation back. The supervisor also
   health-gates every launch on `/health` and stops only when the task itself
   creates `DONE` in the workspace (or MAX_TRIES=50).
3. No recorded session (first run / recording off) → fallback to a
   resume-from-workspace-state prompt.

The supervisor appends crash-safety rules to the initial prompt (persist in
small increments, git commit constantly) — the 2026-09-08 run lost a 26K-token
design because the model kept it all in one 3 h reply (later salvaged from the
recorded session JSONL — another reason chat recording must stay on).

```sh
daemon -o /dev/null /data/local-ai/qwen-super.sh \
  ~/task/project ~/task/PROMPT.md ~/task/qwen.log        # FreeBSD host
```

Knobs: `MAX_TRIES DONE_FILE HEALTH_URL` (+ `REMOTE_MODEL COMPACT` pass through).

**Proof it works (2026-09-10): a real ISP outage 14:13→15:00 UTC hit a live
47 h run and it survived autonomously, zero work lost.** Mechanics observed:
the tunnel loop churned every ~2.5 min (ServerAlive 30×4 → ~120 s dead-peer
detection, then 5 s sleep and reconnect — connections die instantly when the
ISP is down, so the loop just spins cheaply); qwen's in-flight fetch HUNG
(node fetch has no response timeout) until its dying ssh channel sent a
socket RST, which bounced the request into the SDK retry layer (layer 1) —
when the ISP returned, the next retry succeeded and the turn continued.
Supervisor stayed at attempt 1/50 the whole time. Optional hardening if
faster mid-stream recovery matters: `ServerAliveInterval=10 CountMax=2`
(~20 s detection → quicker RST → shorter client hangs) at the cost of more
tunnel churn on flaky-but-alive links.

**Plan for "mega-turns": single model turns of 10.9K and 12.1K output tokens
(~5–6 h each at deep-ctx speeds) were observed writing whole modules.** No
output for hours is NORMAL — check the server log (`n_gen` climbing) before
assuming a hang. The crash-safety prompt makes the model commit only at
green-test milestones; a mega-turn's file writes land mid-turn, so the
workspace can be hours newer than the last commit.

## Generation speed vs context depth

Measured on Ornith Q8_0 (2026-09-08): tg 3.0 t/s @24K ctx → 2.46 @27K → 1.34
@53K (KV scan on the 15 full-attn layers; deep prefill also drops 26→8 t/s).

**Real long-run curve (2026-09-11, 46+ h continuous agent run, YARN=1, 262K
ctx, measured via `/slots` + server log):** tg 1.6 @33K → 0.73 @110K → 0.72
@146K → 0.62 @~160K → 0.55 @179K → ~0.50 @185K. pp on deep prefills 3.5–9 t/s.
Short tool-call turns bounce 0.37–0.67 (KV locality). The earlier
extrapolation held: expect ~0.4–0.5 t/s approaching 256K. Context grows
~2.4–3.3K tok/h in a test/fix coding loop, so a 262K window lasts multiple
DAYS of unattended work before qwen's 0.95 auto-compact fires (~249K).
Measure real usage via `/slots` (`n_prompt_tokens`); the task-id proxy in the
log underestimates badly because tool results re-enter the prompt.

The decay is physics (attention cost grows with depth), but its impact can be cut:

- **client**: `COMPACT` (auto-compact threshold) — **POLICY (owner,
  2026-09-09): default 0.9 (0.95 fine); optional speed setting allowed but
  never below 0.5.** Compaction is LOSSY summarization (older turns get
  replaced by a model-written summary — not compression), and we prioritize
  full-context quality; the depth decay is an accepted cost. Extrapolated
  decay: ~0.9 t/s @100K, ~0.4–0.5 t/s @256K (tg ≈ 1/(a+b·depth), no floor).
  `COMPACT=0.5` caps working ctx at ~131K (~0.7-0.8 t/s worst case) as the
  most aggressive sanctioned trade; if that is still too slow, the answer is
  a faster model/rig (GLM PR, single-node small-quant, laptop GPU hybrid),
  not deeper compaction.
- **server** (A/B/C benched 2026-09-09 — **defaults won, keep OFF**): 128-tok
  gen at 16K/32K/49K depth, loopback on the main node:
  | config | pp t/s (16/32/49K) | tg t/s (16/32/49K) |
  |---|---|---|
  | A defaults (T16, no FA, f16 KV) | **27.6 / 22.1 / 18.6** | **3.33 / 2.20 / 2.29** |
  | B `FA=on KVQ=q8_0` | 18.1 / 11.4 / 7.9 | 3.13 / 2.21 / 1.83 |
  | C `THREADS=24` | 26.9 / 21.8 / 18.0 | 2.70 / 2.78 / 1.81 |
  CPU flash-attn collapses prefill (2–2.6x slower) and the q8_0-KV dequant
  eats the smaller-KV win; T24 helps only a narrow mid-depth band and loses
  elsewhere (tg is RAM-bandwidth-bound). Knobs remain for re-testing on new
  llama.cpp versions/models. Bench harness: `remote/bench-ab.py` (runs on the
  main node; note: first request after a fresh load pays expert page-in — warm
  the server or discard the first row).

## Idle cost of leaving the stack up (no clients)

- **CPU ~0** (all processes are event-driven, block on sockets) and **disk growth 0**
  (no caches, logs only grow per request).
- **RAM is the only cost, and it's asymmetric:**
  - *Helpers stay hot forever*: their ~150 GB of tensors live in anonymous heap and
    the nodes have **no swap** — the kernel physically cannot page them out.
  - *Main self-cools*: ~145 GB of weights are read-only mmap of the .gguf; under
    memory pressure the kernel just drops those pages and re-reads them on demand
    (first request after a quiet spell re-pages, ~1–2 min). Only ~20 GB (KV +
    buffers) stays hard.
- **There is no way to "freeze" helpers to disk while keeping the serving alive**:
  adding swap is a no-go on k8s nodes, SIGSTOP frees no RAM, CRIU checkpointing
  breaks the live RPC TCP sessions (and restoring ~150 GB costs about a reload
  anyway), and ggml-rpc-server has no local-file mmap mode. The only two states
  are: fully hot, or stopped + full ~45 min reload.

## Stopping everything

Kill by PID only (main first is fine; helpers keep running independently):

```sh
# main node:
kill $(pgrep -x llama-server)
# each helper:
kill $(pgrep -x ggml-rpc-server)
```

Nothing persists between runs: no tensor caches are written (removed 2026-09-08
— negligible speedup, ~248 GB of disk). Every start re-streams from the main node.

## Knobs (serve-rpc.sh)

`MODEL PAR YARN NGL PORT RPC THREADS TB SPEC CTX NATIVE FA KVQ` — see the
header of `serve-rpc.sh` for the full story (YaRN 1x/2x/4x context modes, the
tg-decay mitigation knobs, POC mode with small models, and the GLM-5.3-Flash
roadmap note — 2026-09-09 update: the long-ctx collapse bug in PR #27754 turned
out Metal-only, CPU is clean; remaining agent-blocker is the branch's
`supports_tool_calls=false`).
