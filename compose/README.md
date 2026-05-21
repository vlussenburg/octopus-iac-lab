# compose/

Local Octopus Server stack — HA topology. Two Octopus Server nodes share one SQL DB and one set of named volumes, fronted by an nginx load balancer. Two polling-tentacle workers poll the LB and execute deployment steps. The runtime that [`../tofu/`](../tofu/) then configures.

```
   ┌─────────────────────────────────────────────────────────┐
   │                      lb (nginx)                         │
   │     :80 (HTTP) → :10943 (TCP) → :8443 (TCP)             │
   └──┬──────────────────┬────────────────────────────┬──────┘
      │                  │                            │
      ▼                  ▼                            ▼
 ┌──────────┐      ┌──────────┐         ┌────────────────────────┐
 │octopus-1 │      │octopus-2 │         │ workers (polling)      │
 │  Node1   │      │  Node2   │         │ - default-pool-worker  │
 └────┬─────┘      └────┬─────┘         │ - prod-pool-worker     │
      │                 │               └────────────────────────┘
      │ shared volumes  │
      ▼                 ▼
 ┌────────────────────────┐
 │      db (mssql)        │
 └────────────────────────┘
```

Host ports (LB-exposed):
- `8090` → LB `:80` → either node's `:8080` (HTTP API + UI, round-robin)
- `10943` → LB `:10943` → either node's `:10943` (Halibut, TCP)
- `18443` → LB `:8443` → either node's `:8443` (KLOS / Argo Gateway gRPC, TCP)

| File | Purpose |
|------|---------|
| [`docker-compose.yml`](docker-compose.yml) | The HA stack. SQL Server + 2× Octopus + nginx LB + 2 polling-tentacle workers. Apple-Silicon ready (all images `linux/amd64`; turn on Docker Desktop → "Use Rosetta"). |
| [`nginx.conf`](nginx.conf) | LB config. `http {}` for UI/API with WebSocket upgrade headers (SignalR), `stream {}` for raw-TCP Halibut + KLOS. Round-robin, no sticky sessions — HTTP state is in the DB so it's safe. |
| Licence | Set `OCTOPUS_SERVER_BASE64_LICENSE` in the repo-root `.env`. `install.sh` applies it on octopus-1's first boot. octopus-2 skips the licence step (node 1 already did it). |

Reads `MASTER_KEY` from the repo-root `.env`. Both nodes use the same key — that's the whole point of HA: shared DB encryption.

## Run

From the **repo root** (so `--env-file .env` resolves):

```bash
make up        # docker compose up -d  (db → octopus-1 → octopus-2 → lb → workers)
make down      # stop + remove containers (data persists in named volumes)
make logs      # tail logs across all services
make nuke      # ⚠️ wipe all volumes — DB, repository, artifacts, taskLogs, worker configs
```

First boot takes ~90–120s (octopus-1 must be healthy before octopus-2 joins; workers register once `make cp-apply` has created `prod-pool`). Then:

```bash
open http://localhost:8090
```

Login: `admin` / `Password01!`. If you didn't set `OCTOPUS_SERVER_BASE64_LICENSE` in `.env` before `make up`, paste under Configuration → License now. The dashboard's Configuration → Nodes page should show both `OctopusNode1` and `OctopusNode2`; Infrastructure → Workers should show `default-pool-worker` and `prod-pool-worker`.

## Why HA at all?

Single-node Octopus quietly skips the things that bite in production: node coordination via the DB, master-key consistency across nodes, shared task queue distribution. Running two nodes from minute one exercises the right code paths and catches HA-specific bugs early.

The single-host caveat: this works because both nodes hit the same Linux kernel, so fcntl/flock advisory locks behave correctly across the shared volumes. Across multiple hosts you'd need NFS / EFS / Azure Files — same trick `tofu/k8s-agent/` uses for the K8s side via the NFS CSI driver.

## Why these choices

- **Host port 8090** — 8080 is reserved for a local ArgoCD port-forward.
- **`linux/amd64` pinned on both Octopus + SQL Server images** — Octopus isn't published for arm64; Rosetta makes this acceptable on M-series Macs.
- **Named volumes** — survive container recreation. Both Octopus nodes mount the same `octopus-repository` / `-artifacts` / `-tasklogs`; each worker has its own `*-tentacle-config` / `-home` for its identity + thumbprint. `make nuke` is the only way to drop them.
- **`MASTER_KEY` lives in `.env`** — this key encrypts secrets in the Octopus DB. Changing it after first boot makes existing encrypted data unreadable, so it's generated once and held still.
- **Workers are privileged** — the `octopusdeploy/tentacle:latest` image always starts a Docker-in-Docker daemon and DinD requires `privileged: true`. Sandbox-only choice.
- **Workers poll the LB, not a specific node** — `ServerCommsAddress: Polling://lb:10943/` means worker connections round-robin across both Octopus nodes, so HA actually load-balances the work.
- **`18443:8443` for gRPC** — Docker Desktop reserves `*:8443` on macOS, so we bind 18443 on the host. The LB container still listens on 8443; Argo Gateway uses `grpc://host.docker.internal:18443`.

## Resource sizing

Docker Desktop allocates a single memory pool across the compose stack AND the Docker Desktop Kubernetes cluster. Limits set in `docker-compose.yml`:

| Service | mem_limit | cpus |
|---|---|---|
| `db` (SQL Server, `MSSQL_MEMORY_LIMIT_MB=2048`) | 4 GB | 2 |
| `octopus-1` / `octopus-2` (each) | 2 GB | 2 |
| `lb` (nginx) | 256 MB | 1 |
| `default-pool-worker` / `prod-pool-worker` (each) | 1.5 GB | 2 |

Total compose footprint: ~11.5 GB, leaving ~4.5 GB for Docker Desktop K8s + system.

**Recommendation: Docker Desktop → Settings → Resources → 16 GB.** With HA + workers running, anything less and you'll feel it.
