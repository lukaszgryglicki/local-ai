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

Defaults to the 3-node model (`ornith15-397b`: 524,288 ctx/slot, temp 0.6,
top-p 0.95, top-k 20, no client-side timeouts). Legacy single-node model instead:

```sh
REMOTE_MODEL=qwen38flash /data/local-ai/qwen-remote.sh
```

Notes: the FIRST request after a server start takes ~1–2 min extra (the main
node pages its ~150 GB of local layers into RAM). Expected steady speed for
Ornith Q8_0: ~24 t/s prompt processing, ~4.5 t/s generation. Server allows 4
parallel requests (slots).

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

`MODEL PAR YARN NGL PORT RPC THREADS TB SPEC CTX NATIVE` — see the header of
`serve-rpc.sh` for the full story (YaRN 1x/2x/4x context modes, POC mode with
small models, and the GLM-5.3-Flash roadmap note).
