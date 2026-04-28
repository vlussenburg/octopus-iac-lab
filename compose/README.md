# compose/

Local Octopus Server stack in **HA mode**: two Octopus nodes share one SQL DB and a set of named volumes, fronted by an nginx LB. The runtime that [`../tofu/`](../tofu/) then configures.

| File | Purpose |
|------|---------|
| [`docker-compose.yml`](docker-compose.yml) | `db` + `octopus-1` + `octopus-2` + `lb`. Apple-Silicon ready (Octopus + SQL forced to `linux/amd64`; turn on Docker Desktop → "Use Rosetta" for native-ish speed). Project name pinned to `selfhost-setup` so volumes are stable. |
| [`nginx.conf`](nginx.conf) | LB config — `http {}` for UI/API on `8090` (with WebSocket upgrade for SignalR), `stream {}` for Halibut polling on `10943` and KLOS gRPC on `8443`. |
| `license.xml` | Octofront licence. **Gitignored.** The Makefile's `up` target base64-encodes it and passes through as `OCTOPUS_SERVER_BASE64_LICENSE`; `install.sh` applies it on first node's boot. |

Reads `MASTER_KEY` from the repo-root `.env` — both Octopus nodes use the same key (required for HA).

## Topology

```
                         ┌──── octopus-1 (NodeName=OctopusNode1)
host:8090 ── lb (nginx) ─┤
host:10943               └──── octopus-2 (NodeName=OctopusNode2)
host:8443                       │
                                ▼
                                db (mssql) + shared named volumes
                                (repository, artifacts, taskLogs)
```

## Run

From the **repo root**:

```bash
make up        # docker compose up -d
make down      # stop + remove containers (data persists in named volumes)
make logs      # tail all services
make nuke      # ⚠️ remove volumes too — wipes the DB and master key
```

First boot takes ~90–120s — node 2 waits for node 1's healthcheck so DB migrations and master-key setup don't race. Then:

```bash
open http://localhost:8090
```

Login: `admin` / `Password01!`. Licence applied automatically from `compose/license.xml` if present.

## Why these choices

- **Single-host HA**: both nodes mount the same named volumes. Works because they hit the same Linux kernel — `fcntl`/`flock` advisory locks behave correctly across containers. Across multiple hosts you'd swap the named volumes for NFS/EFS/Azure Files.
- **Host port 8090** — 8080 is reserved for a local ArgoCD port-forward.
- **`linux/amd64` pinned on Octopus + SQL** — Octopus image isn't published for arm64. nginx is multi-arch.
- **`MASTER_KEY` lives in `.env`** — encrypts secrets in the Octopus DB. Changing it after first boot makes existing encrypted data unreadable. Both nodes must share it.
- **Node 1 applies licence, node 2 doesn't** — `OCTOPUS_SERVER_BASE64_LICENSE` is only set on node 1; node 2 sees a licence already in the DB.
- **No session affinity in the LB** — UI/API state is in the DB, polling tentacles reconnect on failover. Add `ip_hash` if SignalR reconnect storms get noisy.
