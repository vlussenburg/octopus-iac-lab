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
