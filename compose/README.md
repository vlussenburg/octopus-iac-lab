# compose/

Local Octopus Server stack — the runtime that [`../tofu/`](../tofu/) then configures. Services: SQL Server, Octopus Server, and polling-tentacle workers that register into Octopus as `default-pool-worker` (built-in Default Worker Pool) and `prod-pool-worker` (`prod-pool`).

| File | Purpose |
|------|---------|
| [`docker-compose.yml`](docker-compose.yml) | `db` (SQL Server 2022) + `octopus` (Server) + `default-pool-worker` + `prod-pool-worker` (polling tentacles). Host port `8090`. Apple-Silicon ready (all images `linux/amd64`; turn on Docker Desktop → "Use Rosetta"). |
| Licence | Set `OCTOPUS_SERVER_BASE64_LICENSE` in the repo-root `.env` (base64 of your licence XML) — `install.sh` applies it on first boot. If unset, paste via the UI under Configuration → License after first login. |

Reads `MASTER_KEY` and `OCTOPUS_API_KEY` from the repo-root `.env`. The workers need `OCTOPUS_API_KEY` to self-register; they retry until `make cp-apply` has created `prod-pool`.

## Run

From the **repo root** (so `--env-file .env` resolves):

```bash
make up        # docker compose up -d  (db → octopus → workers)
make down      # stop + remove containers (data persists in named volumes)
make logs      # tail logs across all services
make nuke      # ⚠️ remove volumes too — wipes the DB, master key, worker identities
```

First boot takes ~60–90s. Then:

```bash
open http://localhost:8090
```

Login: `admin` / `Password01!`. If you didn't set `OCTOPUS_SERVER_BASE64_LICENSE` in `.env` before `make up`, paste a licence under Configuration → License now. After `make cp-apply`, Infrastructure → Workers shows `default-pool-worker` and `prod-pool-worker`.

## Why these choices

- **Host port 8090** — 8080 is reserved for a local ArgoCD port-forward.
- **`linux/amd64` pinned on all images** — the Octopus images aren't published for arm64; Rosetta makes this acceptable on M-series Macs.
- **Named volumes** — `mssql-data`, `octopus-repository`, `octopus-artifacts`, `octopus-tasklogs` (server-side) plus `default-pool-tentacle-config/-home` and `polling-tentacle-config/-home` (worker identities + thumbprints). Survive container recreation. `make nuke` is the only way to drop them.
- **`MASTER_KEY` lives in `.env`** — encrypts secrets in the Octopus DB. Changing it after first boot makes existing encrypted data unreadable, so it's generated once and held still.
- **Workers are `privileged: true`** — the `octopusdeploy/tentacle:latest` image always starts a Docker-in-Docker daemon; DinD requires privileged. Sandbox-only choice.
- **Octopus host port `18443:8443`** for gRPC — Docker Desktop reserves `*:8443` on macOS, so we bind 18443 on the host. The container listens on 8443; Argo Gateway uses `grpc://host.docker.internal:18443`.

## Resource sizing

Limits set in `docker-compose.yml`. Budget targets a 16 GB Docker Desktop allocation.

| Service | mem_limit | cpus |
|---|---|---|
| `db` (SQL Server, `MSSQL_MEMORY_LIMIT_MB=2048`) | 4 GB | 2 |
| `octopus` | 2 GB | 2 |
| `default-pool-worker` / `prod-pool-worker` (each) | 1.5 GB | 2 |

Total compose footprint: ~9 GB, leaving ~7 GB for Docker Desktop K8s (which hosts the K8s agent + ArgoCD + nginx-ingress + the deployed apps) + system.

**Set Docker Desktop → Settings → Resources → 16 GB.** Less than that and you'll feel it.
