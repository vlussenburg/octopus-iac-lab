# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project purpose

Personal lab for scaffolding a self-hosted Octopus Server entirely as code, with Config-as-Code (CaC) on from minute one. Project state lives in Git (`.octopus/*.ocl`) rather than the Octopus database. Sandbox only — not a reference for production.

The lab is dual-target: the same OCL + tofu drives both a **local self-hosted** Octopus (this worktree) and an **Octopus Cloud SaaS** instance (a sibling worktree). The two are kept in lock-step via the shared `.octopus/` and `tofu/` and differentiated only by `.env`.

## Common commands

All `make` targets run from the **repo root**. The Makefile loads `.env` once and re-exports `OCTOPUS_URL` / `OCTOPUS_API_KEY` / `GITHUB_PAT` as `TF_VAR_*` for OpenTofu.

```bash
# Local Octopus Server (compose/) — local worktree only
make up | down | logs | ps | nuke   # nuke deletes volumes — wipes DB + master key

# Per-stack
#   space  = tofu/space/             (the kill-switch Space)
#   cp     = tofu/control-plane/     (envs, lifecycle, project group, tenants, library vars, GHCR feed)
#   ph     = tofu/platform-hub/      (Platform Hub Git wiring)
#   app    = tofu/app-randomquotes/  (the CaC project)
#   agent  = tofu/k8s-agent/         (K8s agent + shared cluster infra)
make {space,cp,ph,app,agent}-{init,plan,apply,destroy,fmt,validate}

# Convenience
make fmt validate                   # all stacks
make apply                          # space → cp → ph → app → agent
make destroy                        # reverse order
```

First-time bootstrap order: `make up` → log in at `localhost:8090` → mint API key + paste `compose/license.xml` via UI → fill `.env` (`OCTOPUS_URL`, `OCTOPUS_API_KEY`, `GITHUB_PAT`, `MASTER_KEY`) → `make apply`.

## Architecture

### Layout

1. **`compose/`** — docker-compose runtime (SQL Server 2022 + Octopus Server, both pinned `linux/amd64`). Host port `8090`. Reads `MASTER_KEY` from `.env`. Optional `OCTOPUS_SERVER_BASE64_LICENSE` in `.env` is applied by `install.sh` on first boot (otherwise paste via UI). Local worktree only — the SaaS worktree has no compose stack.
2. **`tofu/`** — six independent OpenTofu stacks, each with its own local `terraform.tfstate`. Intentionally split, not modules. One reusable local module under `tofu/modules/octopus-argocd-gateway/` placeholders a future provider resource (`octopusdeploy_argocd_gateway`).
3. **`gitops/`** — Argo CD's source of truth: App-of-Apps roots (one per worktree) and 12 per-tenant leaf `Application` YAMLs. Edits here propagate to the cluster on the next Argo poll, no `tofu apply`.
3. **`.octopus/`** — OCL files owned by Octopus. Octopus serialises deployment process / settings / variables / runbooks here on every UI save and commits via the configured Git credential. **Folder name is fixed** — Octopus rejects anything other than `.octopus`.

### Cross-stack state sharing

Downstream stacks read upstream outputs via `terraform_remote_state` with `backend = "local"` pointing at sibling state files. The chain: `space` → `control-plane` → (`platform-hub` | `app-randomquotes` | `k8s-agent`). `app` and `agent` also read `control-plane`. Apply order is enforced by the Makefile.

| Stack | Owns |
|---|---|
| `tofu/space/` | The non-default `IaC Sandbox` Space (slug pinned to `iac-sandbox`). Kill switch — destroying it cascades through every project, env, lifecycle, target inside. Both `teams-administrators` and `teams-managers` listed as Space managers (the bootstrap user lives in different teams on local vs SaaS). |
| `tofu/control-plane/` | Environments (`Dev`/`Production`), lifecycle, project group, GHCR external feed, library variable set (carries `Source = local|saas` per-Octopus + brand/tier defaults), tenant tag sets (mood/tier/app), three tenants (`acme-corp`/`globex`/`initech`) with per-tenant variables, tenant logos (uploaded via `null_resource` + curl to `/api/.../tenants/{id}/logo`), GitHub PAT Git credential. |
| `tofu/platform-hub/` | Octopus Platform Hub Git wiring (`/api/platformhub/versioncontrol` + `/api/platformhub/git-credentials`). Gated by `OCTOPUS_PLATFORM_HUB_ENABLED` (default `true`) so SaaS targets without the feature can opt out. |
| `tofu/app-randomquotes/` | The `randomquotes` project resource only — `is_version_controlled = true`, `is_disabled = false`, `tenanted_deployment_participation = "Tenanted"`. The deployment process and runbooks are NOT declared in HCL — they live in `.octopus/deployment_process.ocl` and `.octopus/runbooks/*.ocl`. The library variable set from control-plane is included on the project. |
| `tofu/k8s-agent/` | NFS CSI driver + nginx-ingress controller (shared cluster infra installed via `helm upgrade --install`, deliberately survives `make destroy`) + Octopus K8s Agent Helm release + a `kubernetes_namespace_v1` for the agent + a destroy-time `null_resource` that DELETEs the registered deployment target out of Octopus on `agent-destroy` (otherwise it orphans and blocks env deletion). The agent self-registers tagged with role `k8s` (which `deployment_process.ocl` targets), bound to Dev + Production, and tenant-participating. |
| `tofu/argocd/` | Minimum-footprint stack — owns only the **control plane** of the Octopus↔Argo connection: ArgoCD helm install (gated `install_argocd`, local owns), the `octopus`-account JWT mint, and the Octopus Argo CD Gateway via the `octopus-argocd-gateway` local module. The helm install also seeds a single bootstrap Application via `extraObjects`. Everything else — App-of-Apps roots, ingress, 12 leaf Applications — lives in [`gitops/`](../gitops/) and is reconciled from git, not tofu state. |

### Secrets vs config split

- `.env` (gitignored): `MASTER_KEY`, `OCTOPUS_URL`, `OCTOPUS_API_KEY`, `GITHUB_PAT`. Optionally `OCTOPUS_SERVER_BASE64_LICENSE`, `OCTOPUS_PLATFORM_HUB_ENABLED`, `OCTOPUS_URL_FROM_CLUSTER`, `OCTOPUS_POLLING_URL_FROM_CLUSTER`.
- `tofu/<stack>/defaults.auto.tfvars` (committed): non-sensitive lab values (space name, CaC repo URL/branch/base path, agent name, chart version, etc.).
- The Makefile is the only thing that bridges `.env` → `TF_VAR_*`. Don't add `terraform.tfvars` files for these.

### Auth model (lab-only choices)

- **Octopus → GitHub (CaC commits + Platform Hub)**: GitHub PAT with `repo` scope, stored as Octopus Git credentials in `control-plane` and `platform-hub`.
- **K8s agent → Octopus**: admin API key passed as `agent.bearerToken` in the Helm chart. Octopus accepts API keys as `Authorization: Bearer`. Replace with a scoped service-account key for anything non-sandbox.
- **KLOS / kubernetes monitor**: deliberately disabled — would require exposing gRPC `8443` from the compose stack.

### Compose quirks worth knowing

- Host port is **8090** (not 8080) because 8080 is reserved for an ArgoCD port-forward on this machine.
- Both images forced to `linux/amd64`; enable Docker Desktop "Use Rosetta" on Apple Silicon.
- Polling tentacle port is `host.docker.internal:10943` (Halibut, TLS over TCP) — different from the HTTP API.

### Image + CI

- App image is **built from this repo** by `.github/workflows/build.yml` and pushed to `ghcr.io/vlussenburg/octopus-iac-lab`. The control-plane stack registers GHCR as an external feed; the deployment process pulls the image from there.
- `.github/workflows/release.yml` is a reusable workflow called by `build.yml` once per Octopus target via a job matrix (SaaS + Local). It creates a release on the chosen Octopus and deploys it tenanted via `OctopusDeploy/deploy-release-tenanted-action@v3` (the non-tenanted action doesn't support tenants).
- Local Octopus is reachable from GHA via Tailscale Funnel; if the funnel is down the local matrix leg cleanly skips with `continue-on-error: true`.

### Tenants + namespaces

Three tenants (`acme-corp`/`globex`/`initech`), each tagged with `tier/{free,pro,enterprise}` (drives replicas + watermark), `mood/{comedy,silicon-valley,stoic}` (drives quote pool), and the `app/randomquotes` participation tag. Combined with two envs and two `Source` values (local/saas), this fans out to **12 namespaces** of the form `randomquotes-#{Source}-#{Octopus.Deployment.Tenant.Name}-#{Octopus.Environment.Name | ToLower}`.

`Source` is supplied via the `Lab Defaults` library variable set, which differs per Octopus instance — it's not derived from the URL via Substring (we tried; library variable set is cleaner).

### Ingress

Apps are reached via the cluster's nginx-ingress controller at `*.localtest.me` (which resolves to 127.0.0.1). One `kubectl port-forward svc/ingress-nginx-controller 80:80 -n ingress-nginx` covers all 12 tenant×env combinations. Hostnames are `#{Source}-#{tenant}-#{env}.localtest.me`. The ArgoCD UI also rides this ingress at `argocd.localtest.me:8080`.

### GitOps + push: two delivery paths into one project

Two parallel deployment shapes drive the same `randomquotes` Octopus project:

- **Push** (the K8s agent): Octopus runs the `deployment_process.ocl` steps directly; manifests are inlined in OCL. Deploys into `randomquotes-{source}-{tenant}-{env}` namespaces.
- **GitOps** (Argo CD via the Octopus Gateway): Argo Applications carry `argo.octopus.com/{project,environment,tenant}` annotations; the Gateway watches the cluster and surfaces them under Infrastructure → Argo CD Instances. Source manifests live in `gitops/k8s/{dev,production}/` — per-env folders. Octopus's `Octopus.ArgoCDUpdateImageTags` step runs on whichever env the deployment targets and writes only to that env's folder (the leaf Apps' `spec.source.path` enforces the separation). Promotion = deploying the same Octopus release to the next env. Deploys into `argo-randomquotes-{source}-{tenant}-{env}` namespaces (separate prefix avoids collision with the agent path).

The `OctopusDeploy/octopusdeploy` provider has zero Argo CD resources as of v1.12 — `tofu/modules/octopus-argocd-gateway/` placeholders the schema we'd hope they'll ship for the Gateway connection, so the eventual migration is "swap the implementation, keep the call sites".

## Editing rules of thumb

- **Don't redefine deployment process / variables / channels / runbooks in HCL.** They are owned by `.octopus/*.ocl`. Either edit OCL by hand and commit, or edit in the Octopus UI and let it commit.
- **Don't pre-populate `.octopus/`.** Let Octopus seed each file on first save so the schema matches the running server.
- **`MASTER_KEY` is generated once.** Changing it after first boot makes existing encrypted data unreadable.
- The `octopusdeploy` provider is `OctopusDeploy/octopusdeploy ~> 1.12` (the official one, not the older `OctopusDeployLabs/` fork). The k8s-agent stack additionally uses `helm` and `kubernetes` providers and requires Docker Desktop Kubernetes enabled.
- `gitops/k8s/{dev,production}/` is the source-of-truth for the **GitOps path** (Argo Applications sync from there). It's **not** used by the agent's deployment process, which inlines its own manifests in `.octopus/deployment_process.ocl`. Manifests there have no hardcoded namespace — Argo's `destination.namespace` and `CreateNamespace=true` syncOption handle materialisation per-Application. Octopus's `Octopus.ArgoCDUpdateImageTags` step runs for whichever env the deploy targets and writes to that env's source folder only — env separation is enforced via per-env `spec.source.path` on the leaves.
