# octopus-iac-lab

A personal lab for scaffolding and configuring a **self-hosted Octopus Server** entirely as code, with **Config-as-Code (CaC)** turned on so project state lives in Git rather than the Octopus database.

## Why this exists

- I wanted IaC-driven setup of Octopus (envs, lifecycles, project groups, projects, Git credentials, K8s agent).
- I wanted CaC enabled from minute one — so the project's deployment process serialises out to OCL files in Git, not into the SQL database.
- This is intentionally a "prissy techy" setup. No customer is shipping their first Octopus install this way; the goal is to learn the IaC + CaC surface end-to-end against my own sandbox.

## Layout

```
octopus-iac-lab/
├── compose/      # docker-compose stack — the local Octopus Server
├── tofu/         # OpenTofu — three stacks (control-plane, app, k8s-agent)
├── app/          # the actual app artefacts (Dockerfile, index.html, k8s/)
└── .octopus/     # OCL files — owned by Octopus + git via CaC
```

Each folder has its own `README.md`. Non-sensitive lab config lives in committed `tofu/<stack>/defaults.auto.tfvars`. Secrets live in `.env` (gitignored).

## Target server

Local self-hosted Octopus, defined right here in [`compose/docker-compose.yml`](compose/docker-compose.yml):

| | |
|---|---|
| URL | `http://localhost:8090` |
| Admin login | `admin` / `Password01!` |
| Space | `Default` (`Spaces-1`) |
| Polling (Halibut) | `host.docker.internal:10943` |
| gRPC (KLOS, off by default) | `host.docker.internal:8443` |

## Bootstrap

1. Copy `.env.example` → `.env` and fill in `MASTER_KEY` (generate with `openssl rand -base64 16`).
2. Start the server: `make up`
3. Log in at <http://localhost:8090>, mint an API key (Profile → My API Keys), paste `compose/license.xml` under Configuration → License.
4. Create a GitHub PAT with `repo` scope. Add `OCTOPUS_API_KEY` + `GITHUB_PAT` to `.env`.
5. From the repo root:
   ```bash
   make cp-init && make cp-apply         # control-plane: envs, lifecycle, project group, Git credential
   make app-init && make app-apply       # randomquotes project (CaC-enabled)
   make agent-init && make agent-apply   # NFS CSI + Octopus K8s Agent (needs Docker Desktop K8s)
   ```
   Or just `make apply` to chain all three.

After `make app-apply`, the deployment process in [`.octopus/deployment_process.ocl`](.octopus/deployment_process.ocl) is live in Octopus. After `make agent-apply`, the K8s agent registers as a deployment target with role `k8s` — which the deployment step targets. Creating + deploying a release deploys [`app/k8s/`](app/k8s/) into the local cluster.

## Auth notes

- **Octopus → GitHub (CaC)**: GitHub PAT with `repo` scope.
- **Agent → Octopus**: admin API key as Bearer (Octopus accepts API keys for `Authorization: Bearer`). Localhost-lab choice; for anything real, scope a service account.
- **Stale API key recovery**: `make apply` and `make destroy` first probe `OCTOPUS_API_KEY` against `/api/users/me`. If rejected on local, the Makefile mints a fresh key and updates `.env`. On SaaS it fails with a UI link — SaaS keys can't be minted programmatically without a browser session.

## Deploys

Deploys come from CI ([`.github/workflows/deploy.yml`](.github/workflows/deploy.yml)). Push to `main` → image built and pushed to GHCR → release created on each Octopus and deployed to `Dev`. Promotion to `Production` is a manual step in the Octopus UI.

The workflow fans out via a job matrix to two targets — **SaaS** and **Local** — using one set of secrets each:

| Secret | Value |
|---|---|
| `OCTOPUS_SAAS_URL` | `https://<id>.octopus.app` |
| `OCTOPUS_SAAS_API_KEY` | API key on that SaaS instance |
| `OCTOPUS_LOCAL_URL` | Public URL for the local Octopus (see below). Empty → local job is cleanly skipped. |
| `OCTOPUS_LOCAL_API_KEY` | API key on the local Octopus |

The local target is `continue-on-error: true` — if the tunnel's down or the secrets are blank, the SaaS deploy still succeeds and the pipeline reports the local leg as a non-fatal warning.

### Exposing local Octopus to GitHub Actions

Local Octopus runs on `localhost:8090`, which GitHub Actions runners can't reach. **Tailscale Funnel** is the lightest setup — free for personal use, stable URL across sessions, no DNS work:

```bash
brew install tailscale
sudo tailscaled install-system-daemon                              # if not already running
tailscale up                                                       # signs you in
# In admin.tailscale.com → Access controls, ensure Funnel is enabled.
tailscale funnel --bg --https=443 http://localhost:8090
```

The funnel URL is printed by the command — `https://<host>.<tailnet>.ts.net`. Set that as `OCTOPUS_LOCAL_URL` in GitHub Actions secrets once. CI deploys to local whenever the funnel is up; the local matrix leg cleanly skips (with a warning) when it's not.

Halibut polling (`:10943`) is still over the docker-desktop loopback for the agent; the funnel is only for the API path GHA needs.

Alternative: **Cloudflare Tunnel** if you want a custom domain (free, requires the domain in Cloudflare, slightly more setup):

```bash
brew install cloudflared
cloudflared tunnel login
cloudflared tunnel create octopus-iac-lab
cloudflared tunnel route dns octopus-iac-lab octopus.example.com
# config.yml ingress: octopus.example.com → http://localhost:8090
cloudflared tunnel run octopus-iac-lab
```

## Wiping the lab

Two scopes — pick what you want gone.

- **Just the terraform-managed Octopus state** (envs, lifecycle, project, Platform Hub config, agent registration, K8s namespace + helm release): `make destroy`. Reverse chain runs through every stack and ends with the Space being deleted, which cascades on the Octopus side. Works identically against local self-host and SaaS.

- **Plus the local Octopus DB itself** (master key, audit log, user accounts, the works):
  ```bash
  make destroy
  make nuke    # docker compose down -v --remove-orphans
  ```
  The next `make up && make apply` runs against a fresh database. The previous API key in `.env` is now invalid against the new DB — `make apply`'s first step (`ensure-api-key`) detects that and re-mints automatically.

- **Full cluster cleanup** (orphan CSI driver, leftover empty namespaces if any): the agent stack's destroy already removes its own namespace and pod. The shared NFS CSI driver is intentionally left running — it's installed via `helm upgrade --install` so it survives `make destroy` and serves any other agents on the cluster. Remove it explicitly when you're tearing the cluster down:
  ```bash
  helm uninstall csi-driver-nfs -n kube-system
  ```

## Not in scope

- No production guidance — this is a sandbox.
- No reference to the `octopus-ttc` demo. App artefacts in `app/` were copied from there but the lab is otherwise standalone.
