# octopus-iac-lab

A personal lab for scaffolding and configuring **Octopus Deploy** entirely as code, with **Config-as-Code (CaC)** turned on so project state lives in Git rather than the Octopus database. The same OCL + tofu drives both a **local self-hosted** Octopus and an **Octopus Cloud SaaS** instance — kept in lock-step from sibling worktrees.

## Why this exists

- I wanted IaC-driven setup of Octopus (space, envs, lifecycles, project group, library vars, tenants, GHCR feed, K8s agent).
- I wanted CaC enabled from minute one — so the project's deployment process and runbooks serialise out to OCL files in Git, not into the SQL database.
- This is intentionally a "prissy techy" setup. No customer is shipping their first Octopus install this way; the goal is to learn the IaC + CaC surface end-to-end against my own sandbox.

## Layout

```
octopus-iac-lab/
├── compose/      # docker-compose stack — local Octopus Server (local worktree only)
├── tofu/         # OpenTofu — six stacks (space, control-plane, platform-hub, app-randomquotes, k8s-agent, argocd) + a local module under tofu/modules/
├── gitops/       # Argo CD's source of truth — App-of-Apps roots + 12 per-tenant leaf Applications
├── app/          # the actual app artefacts (Dockerfile, index.html)
├── assets/       # tenant logos uploaded by control-plane
└── .octopus/     # OCL files — owned by Octopus + git via CaC (deployment process, runbooks, variables)
```

Each folder has its own `README.md`. Non-sensitive lab config lives in committed `tofu/<stack>/defaults.auto.tfvars`. Secrets live in `.env` (gitignored).

## Target server

Local self-hosted Octopus, defined right here in [`compose/docker-compose.yml`](compose/docker-compose.yml):

| | |
|---|---|
| URL | `http://localhost:8090` |
| Admin login | `admin` / `Password01!` |
| Space | `IaC Sandbox` (slug `iac-sandbox`, created by `tofu/space/`) |
| Polling (Halibut) | `host.docker.internal:10943` |
| gRPC (KLOS, off by default) | `host.docker.internal:8443` |

The SaaS worktree points at `https://<id>.octopus.app` instead and skips `compose/` entirely.

## Bootstrap

1. Copy `.env.example` → `.env` and fill in `MASTER_KEY` (`openssl rand -base64 16`), `OCTOPUS_URL` (`http://localhost:8090` or your SaaS URL).
2. Local only: start the server: `make up`. To skip the UI licence-paste step, base64 your licence XML (`base64 -i license.xml | tr -d '\n'`) and set it as `OCTOPUS_SERVER_BASE64_LICENSE` in `.env` before `make up`. Otherwise paste it via the UI under Configuration → License after first login.
3. Log in, mint an API key (Profile → My API Keys).
4. Create a GitHub PAT with `repo` scope. Add `OCTOPUS_API_KEY` + `GITHUB_PAT` to `.env`.
5. From the repo root:
   ```bash
   make space-init && make space-apply   # the IaC Sandbox Space (kill-switch)
   make cp-init    && make cp-apply      # envs, lifecycle, library vars, GHCR feed, tenants, tenant logos
   make ph-init    && make ph-apply      # Platform Hub Git wiring (skip via OCTOPUS_PLATFORM_HUB_ENABLED=false on SaaS without the feature)
   make app-init   && make app-apply     # randomquotes project (CaC-enabled, tenanted)
   make agent-init && make agent-apply   # NFS CSI + nginx-ingress + Octopus K8s Agent (needs Docker Desktop K8s)
   make argo-init  && make argo-apply    # ArgoCD + Octopus Argo CD Gateway + 6 annotated Argo Applications
   ```
   Or just `make apply` to chain all six.

After `make app-apply`, the deployment process in [`.octopus/deployment_process.ocl`](.octopus/deployment_process.ocl) and runbooks in [`.octopus/runbooks/`](.octopus/runbooks/) are live. After `make agent-apply`, the K8s agent registers as a deployment target tagged `k8s` and tenant-participating. CI then builds + deploys the image into 12 tenant×env namespaces.

## Auth notes

- **Octopus → GitHub (CaC + Platform Hub)**: GitHub PAT with `repo` scope.
- **Agent → Octopus**: admin API key as Bearer (Octopus accepts API keys for `Authorization: Bearer`). Localhost-lab choice; for anything real, scope a service account.
- **Stale API key recovery**: `make apply` and `make destroy` first probe `OCTOPUS_API_KEY` against `/api/users/me`. If rejected on local, the Makefile mints a fresh key and updates `.env`. On SaaS it fails with a UI link — SaaS keys can't be minted programmatically without a browser session.

## Deploys

Deploys come from CI. Two workflows:

- [`.github/workflows/build.yml`](.github/workflows/build.yml) — push to `main`, image built and pushed to `ghcr.io/vlussenburg/octopus-iac-lab`, then fans out via a job matrix to call `release.yml` once per Octopus target.
- [`.github/workflows/release.yml`](.github/workflows/release.yml) — reusable workflow. Creates a release on the chosen Octopus and deploys it tenanted via `OctopusDeploy/deploy-release-tenanted-action@v3` to `Dev`. Promotion to `Production` is a manual step in the Octopus UI.

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

## Reaching the deployed app

The k8s-agent stack installs nginx-ingress into `ingress-nginx`. Each deploy gets an `Ingress` for a `*.localtest.me` host (resolves to 127.0.0.1). One port-forward serves the entire lab — every tenant on both delivery paths, plus the ArgoCD UI:

```bash
kubectl port-forward svc/ingress-nginx-controller 8080:8080 -n ingress-nginx

# K8s agent path (Octopus push) — host = {worktree}-{tenant}-{env}.localtest.me
open http://local-acme-corp-dev.localtest.me:8080
open http://saas-globex-production.localtest.me:8080

# ArgoCD path (GitOps pull) — host = argo-{worktree}-{tenant}-{env}.localtest.me
open http://argo-local-acme-corp-dev.localtest.me:8080
open http://argo-saas-globex-production.localtest.me:8080

# ArgoCD UI itself
open http://argocd.localtest.me:8080      # admin password: see argo-apply outputs
```

Side-by-side comparison: each tenant is reachable on **both** paths simultaneously, so `local-acme-corp-dev.localtest.me` (push) and `argo-local-acme-corp-dev.localtest.me` (pull) render the same tenant flavour from two different delivery pipelines.

## Two delivery paths into the same project

`randomquotes` is set up to be deployed two ways at once:

- **Push** (`tofu/k8s-agent/`): the agent runs `Octopus.KubernetesDeployRawYaml` from inlined manifests in `.octopus/deployment_process.ocl`. Namespaces: `randomquotes-{source}-{tenant}-{env}`.
- **GitOps** (`tofu/argocd/` + `gitops/`): the 12 Argo Applications live as YAML files under [`gitops/applications/randomquotes/{local,saas}/`](gitops/applications/randomquotes/) — that's the source of truth, edit them and push. tofu only manages the **control plane** (ArgoCD install, the JWT, and the Octopus Argo CD Gateway connection). The cluster bootstraps itself from git via an App-of-Apps root. Each leaf is annotated with `argo.octopus.com/{project,environment,tenant}` so the Gateway forwards it to the right Octopus. Namespaces: `argo-randomquotes-{source}-{tenant}-{env}`.

Both can deploy concurrently to the same cluster — different namespace prefixes ensure they don't fight. Pick the comparison story you want to tell from one Octopus project.

## Wiping the lab

Two scopes — pick what you want gone.

- **Just the terraform-managed Octopus state** (Space + everything inside it: envs, lifecycle, project, Platform Hub config, tenants, agent registration, K8s namespace + helm release): `make destroy`. Reverse chain runs `agent → app → ph → cp → space`. Destroying the Space is the catch-all — it cascades on the Octopus side. Works identically against local self-host and SaaS. The agent stack's destroy-time `null_resource` removes the registered deployment target before `helm uninstall` so it doesn't orphan and block env deletion.

- **Plus the local Octopus DB itself** (master key, audit log, user accounts, the works):
  ```bash
  make destroy
  make nuke    # docker compose down -v --remove-orphans
  ```
  The next `make up && make apply` runs against a fresh database. The previous API key in `.env` is now invalid against the new DB — `make apply`'s first step (`ensure-api-key`) detects that and re-mints automatically.

- **Full cluster cleanup** (orphan CSI driver + nginx-ingress controller): the agent stack's destroy removes its own namespace and pod. The shared NFS CSI driver and nginx-ingress controller are intentionally left running — they're installed via `helm upgrade --install` so they survive `make destroy` and serve any other agents on the cluster. Remove explicitly when you're tearing the cluster down:
  ```bash
  helm uninstall csi-driver-nfs -n kube-system
  helm uninstall ingress-nginx -n ingress-nginx
  ```

## Not in scope

- No production guidance — this is a sandbox.
- No reference to the `octopus-ttc` demo. App artefacts in `app/` were originally copied from there but the lab is otherwise standalone. K8s manifests come from `gitops/charts/randomquotes/` (used by Argo, with per-tenant values per Application) and are inlined in `.octopus/deployment_process.ocl` (used by the K8s agent).
