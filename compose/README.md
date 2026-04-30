# compose/

Local Octopus Server stack — the runtime that the [`../tofu/`](../tofu/) scaffold then configures.

| File | Purpose |
|------|---------|
| [`docker-compose.yml`](docker-compose.yml) | SQL Server 2022 + Octopus Server, host port `8090`. Apple-Silicon ready (both images forced to `linux/amd64`; turn on Docker Desktop → "Use Rosetta" for native-ish speed). |
| `license.xml` | Octofront licence. **Gitignored.** If present at `make up`, the Makefile base64-encodes it and exports `OCTOPUS_SERVER_BASE64_LICENSE` so the image's `install.sh` applies it on first boot. If absent, paste it via the UI under Configuration → License after first login. |

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

Login: `admin` / `Password01!`. If you didn't drop a `license.xml` in before `make up`, paste one under Configuration → License now.

## Why these choices

- **Host port 8090** — 8080 is reserved for a local ArgoCD port-forward.
- **`linux/amd64` pinned on both images** — the Octopus image isn't published for arm64; Rosetta makes this acceptable on M-series Macs.
- **Named volumes** (`mssql-data`, `octopus-repository`, `octopus-artifacts`, `octopus-tasklogs`) — survive container recreation. `make nuke` is the only way to drop them.
- **`MASTER_KEY` lives in `.env`** — this key encrypts secrets in the Octopus DB. Changing it after first boot makes existing encrypted data unreadable, so it's generated once and held still.
