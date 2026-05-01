# compose/

Local Octopus Server stack — the runtime that the [`../tofu/`](../tofu/) scaffold then configures.

| File | Purpose |
|------|---------|
| [`docker-compose.yml`](docker-compose.yml) | SQL Server 2022 + Octopus Server, host port `8090`. Apple-Silicon ready (both images forced to `linux/amd64`; turn on Docker Desktop → "Use Rosetta" for native-ish speed). |
| Licence | Set `OCTOPUS_SERVER_BASE64_LICENSE` in the repo-root `.env` (base64 of your licence XML) — `install.sh` applies it on first boot. If unset, paste via the UI under Configuration → License after first login. |

Reads `MASTER_KEY` from the repo-root `.env`.

## Run

From the **repo root** (so `--env-file .env` resolves):

```bash
make up        # docker compose up -d
make down      # stop + remove containers (data persists in named volumes)
make logs      # tail octopus logs
make nuke      # ⚠️ remove volumes too — wipes the DB and master key
```

First boot takes ~60–90s. Then:

```bash
open http://localhost:8090
```

Login: `admin` / `Password01!`. If you didn't set `OCTOPUS_SERVER_BASE64_LICENSE` in `.env` before `make up`, paste a licence under Configuration → License now.

## Why these choices

- **Host port 8090** — 8080 is reserved for a local ArgoCD port-forward.
- **`linux/amd64` pinned on both images** — the Octopus image isn't published for arm64; Rosetta makes this acceptable on M-series Macs.
- **Named volumes** (`mssql-data`, `octopus-repository`, `octopus-artifacts`, `octopus-tasklogs`) — survive container recreation. `make nuke` is the only way to drop them.
- **`MASTER_KEY` lives in `.env`** — this key encrypts secrets in the Octopus DB. Changing it after first boot makes existing encrypted data unreadable, so it's generated once and held still.
- **SQL Server memory cap** (`MSSQL_MEMORY_LIMIT_MB=4096`, `mem_limit: 5g`) — without it the engine grows its buffer pool unbounded and starves Octopus + Docker Desktop K8s. Bump up if you grow Docker Desktop's overall allocation.

## Resource sizing

Docker Desktop allocates a single memory pool across the compose stack AND the Docker Desktop Kubernetes cluster (which hosts the K8s agent + ArgoCD + nginx-ingress + the deployed apps). Default 8 GB is tight once the lab is fully wired:

| Consumer | Approx need |
|---|---|
| `db` (SQL Server) | 4 GB cap, ~3 GB working |
| `octopus` | ~2 GB |
| Docker Desktop K8s + ArgoCD + agents + apps | 3–4 GB |

**Recommendation: Docker Desktop → Settings → Resources → bump memory to 12–16 GB.** Then optionally raise `MSSQL_MEMORY_LIMIT_MB` here in step.
