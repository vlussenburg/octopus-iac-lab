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

# Bootstrap helpers (local only — SaaS has no admin/password to script against)
make master-key                     # one-shot: generate MASTER_KEY into .env (refuses to overwrite)
make mint-api-key                   # log in as admin/Password01! and write a fresh OCTOPUS_API_KEY to .env
make ensure-api-key                 # probe current key; if 401, auto-mint locally / fail-with-pointer on SaaS

# Per-stack
#   space  = tofu/space/             (the kill-switch Space)
#   cp     = tofu/control-plane/     (envs, lifecycle, project group, tenants, library vars, GHCR feed)
#   ph     = tofu/platform-hub/      (Platform Hub Git wiring)
#   app    = tofu/app-randomquotes/  (the CaC project)
#   agent  = tofu/k8s-agent/         (K8s agent + shared cluster infra)
#   argo   = tofu/argocd/            (ArgoCD install + Octopus↔Argo Gateway control plane)
#   snow   = tofu/servicenow/        (ServiceNow ITSM connection + extension settings)
make {space,cp,ph,app,agent,argo,snow}-{init,plan,apply,destroy,fmt,validate}

# Convenience
make fmt validate                   # all stacks
make apply                          # ensure-api-key → space → cp → ph → app → agent → argo
make destroy                        # ensure-api-key → reverse order
```

First-time bootstrap (local): fill `.env` with `OCTOPUS_URL`, `GITHUB_PAT`, and optionally `OCTOPUS_SERVER_BASE64_LICENSE` → `make master-key` → `make up` → `make apply`. `apply`/`destroy` depend on `ensure-api-key`, which auto-mints a fresh `OCTOPUS_API_KEY` when the existing one fails (e.g. after `make nuke` rebuilds the DB). The license auto-applies from `OCTOPUS_SERVER_BASE64_LICENSE` on first boot, or paste `compose/license.xml` via the UI. SaaS bootstrap still requires minting the API key in the UI — there's no admin/password to script against.

## Architecture

### Layout

1. **`compose/`** — docker-compose runtime (SQL Server 2022 + Octopus Server, both pinned `linux/amd64`). Host port `8090`. Reads `MASTER_KEY` from `.env`. Optional `OCTOPUS_SERVER_BASE64_LICENSE` in `.env` is applied by `install.sh` on first boot (otherwise paste via UI). Local worktree only — the SaaS worktree has no compose stack.
2. **`tofu/`** — seven independent OpenTofu stacks, each with its own local `terraform.tfstate`. Intentionally split, not modules. One reusable local module under `tofu/modules/octopus-argocd-gateway/` placeholders a future provider resource (`octopusdeploy_argocd_gateway`).
3. **`gitops/`** — Argo CD's source of truth: App-of-Apps roots (one per worktree) and 12 per-tenant leaf `Application` YAMLs. Edits here propagate to the cluster on the next Argo poll, no `tofu apply`.
3. **`.octopus/`** — OCL files owned by Octopus. Octopus serialises deployment process / settings / variables / runbooks here on every UI save and commits via the configured Git credential. **Folder name is fixed** — Octopus rejects anything other than `.octopus`.

### Cross-stack state sharing

Downstream stacks read upstream outputs via `terraform_remote_state` with `backend = "local"` pointing at sibling state files. The chain: `space` → `control-plane` → (`platform-hub` | `app-randomquotes` | `k8s-agent` | `argocd` | `servicenow`). `app` and `agent` also read `control-plane`. Apply order is enforced by the Makefile.

| Stack | Owns |
|---|---|
| `tofu/space/` | The non-default `IaC Sandbox` Space (slug pinned to `iac-sandbox`). Kill switch — destroying it cascades through every project, env, lifecycle, target inside. Both `teams-administrators` and `teams-managers` listed as Space managers; additionally, the API-key user is added to the auto-created `Space Managers` team via `space_managers_membership.tf` (provider-native adopt-via-`import` of `octopusdeploy_team`). Octopus's manual-intervention permission check matches by *direct* team membership, so being a space-manager-of via `Octopus Administrators` isn't enough on its own. |
| `tofu/control-plane/` | Environments (`Dev` sort_order=0 / `Production` sort_order=1), lifecycle, project group, GHCR external feed, library variable set (carries `Source = local|saas` per-Octopus + brand/tier defaults), tenant tag sets (mood/tier/app), three tenants (`acme-corp`/`globex`/`initech`) with per-tenant variables, tenant logos (uploaded via `null_resource` + curl to `/api/.../tenants/{id}/logo`), GitHub PAT Git credential. |
| `tofu/platform-hub/` | Octopus Platform Hub Git wiring (`/api/platformhub/versioncontrol` + `/api/platformhub/git-credentials`). Gated by `OCTOPUS_PLATFORM_HUB_ENABLED` (default `true`) so SaaS targets without the feature can opt out. |
| `tofu/app-randomquotes/` | The `randomquotes` project resource only — `is_version_controlled = true`, `is_disabled = false`, `tenanted_deployment_participation = "Tenanted"`. The deployment process and runbooks are NOT declared in HCL — they live in `.octopus/deployment_process.ocl` and `.octopus/runbooks/*.ocl`. The library variable set from control-plane is included on the project. |
| `tofu/k8s-agent/` | NFS CSI driver + nginx-ingress controller (shared cluster infra installed via `helm upgrade --install`, deliberately survives `make destroy`) + Octopus K8s Agent Helm release + a `kubernetes_namespace_v1` for the agent + Sealed Secrets controller install with key-restore/save null_resources (mirrors the active keypair to `.env` as `SEALED_SECRETS_TLS_B64` so cluster resets keep decrypting existing SealedSecrets) + a destroy-time `null_resource` that DELETEs the registered deployment target out of Octopus on `agent-destroy` (otherwise it orphans and blocks env deletion). The agent self-registers tagged with role `k8s` (which `deployment_process.ocl` targets), bound to Dev + Production, and tenant-participating. |
| `tofu/argocd/` | Minimum-footprint stack — owns only the **control plane** of the Octopus↔Argo connection: ArgoCD helm install (gated `install_argocd`, local owns), the `octopus`-account JWT mint, and the Octopus Argo CD Gateway via the `octopus-argocd-gateway` local module. The bootstrap Application that syncs `gitops/argocd/` is created via a separate `null_resource` + `kubectl apply` after the helm release (NOT via `extraObjects`, which dies on the chicken-and-egg between the Application CRD and the resource referencing it). Everything else — App-of-Apps roots, ingress, 12 leaf Applications — lives in [`gitops/`](../gitops/) and is reconciled from git, not tofu state. |
| `tofu/servicenow/` | ServiceNow ITSM connection (OAuth or basic-auth against a PDI) + per-project `servicenow_change_control_extension_settings`. Only applied when `OCTOPUS_SERVICENOW_ENABLED=true` and a connection exists. The env-level `servicenow_extension_settings` toggle on Production lives in `tofu/control-plane/environments.tf` (always present; harmless without a wired connection). The `demo/servicenow-cr-gate` demo demonstrates the full CR-gate flow on Production deploys. |

### Secrets vs config split

- `.env` (gitignored): `MASTER_KEY`, `OCTOPUS_URL`, `OCTOPUS_API_KEY`, `GITHUB_PAT`. Optionally `OCTOPUS_SERVER_BASE64_LICENSE`, `OCTOPUS_PLATFORM_HUB_ENABLED`, `OCTOPUS_URL_FROM_CLUSTER`, `OCTOPUS_POLLING_URL_FROM_CLUSTER`, `SERVICENOW_USERNAME` + `SERVICENOW_PASSWORD` (basic-auth creds for the ServiceNow PDI used by the `demo/servicenow-cr-gate` demo — paired with an Octopus ITSM connection that holds the instance URL).
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
- `build.yml` also pushes **Octopus Build Information** to both Octopus targets after the image push (`OctopusDeploy/push-build-information-action@v4`), so the release page shows commits + a deep link back to the GHA run.
- Local Octopus is reachable from GHA via Tailscale Funnel; if the funnel is down the local matrix leg cleanly skips with `continue-on-error: true`.
- GHA secrets: `OCTOPUS_LOCAL_URL` / `OCTOPUS_LOCAL_API_KEY` for the local target, `OCTOPUS_SAAS_URL` / `OCTOPUS_SAAS_API_KEY` for SaaS. **After `make nuke` or any other event that rotates the local `OCTOPUS_API_KEY` in `.env`, sync the new key into the GHA secret**, otherwise build-info push (and any future release deploys) fails with `The API key you provided was not valid`:
  ```
  grep '^OCTOPUS_API_KEY=' .env | cut -d= -f2- | gh secret set OCTOPUS_LOCAL_API_KEY
  ```

### Tenants + namespaces

Three tenants (`acme-corp`/`globex`/`initech`), each tagged with `tier/{free,pro,enterprise}` (drives replicas + watermark), `mood/{comedy,silicon-valley,stoic}` (drives quote pool), and the `app/randomquotes` participation tag. **Per-tenant lifecycle scope:** acme-corp is connected to both `Dev` and `Production` (full lifecycle, acts as the canary tenant); globex + initech are `Production`-only — modelling "different customers have different lifecycles". Combined with the envs each tenant participates in and two `Source` values (local/saas), this fans out to **8 namespaces per project** of the form `randomquotes-#{Source}-#{Octopus.Deployment.Tenant.Name}-#{Octopus.Environment.Name | ToLower}` — acme-corp×{Dev,Prod} + globex×Prod + initech×Prod, doubled by Source.

`Source` is supplied via the `Lab Defaults` library variable set, which differs per Octopus instance — it's not derived from the URL via Substring (we tried; library variable set is cleaner).

### Ingress

Apps are reached via the cluster's nginx-ingress controller at `*.localtest.me` (which resolves to 127.0.0.1). One `kubectl port-forward svc/ingress-nginx-controller 80:80 -n ingress-nginx` covers all 12 tenant×env combinations. Hostnames are `#{Source}-#{tenant}-#{env}.localtest.me`. The ArgoCD UI also rides this ingress at `argocd.localtest.me:8080`.

### GitOps + push: two delivery paths into one project

Two parallel deployment shapes drive the same `randomquotes` Octopus project:

- **Push** (the K8s agent): Octopus runs the `deployment_process.ocl` steps directly; manifests are inlined in OCL. Deploys into `randomquotes-{source}-{tenant}-{env}` namespaces.
- **GitOps** (Argo CD via the Octopus Gateway): Argo Applications carry `argo.octopus.com/{project,environment,tenant}` annotations; the Gateway watches the cluster and surfaces them under Infrastructure → Argo CD Instances. Manifests come from a single Helm chart at `gitops/charts/randomquotes/`; each leaf Application supplies its own `helm.valuesObject` (tenant, mood, icon, brandColor, watermark, host, replicaCount, image.tag) so 12 Applications render 12 distinct Deployment + ConfigMap + Ingress sets. Octopus's `Octopus.ArgoCDUpdateImageTags` step bumps `image.tag` only on the Applications matching the deployment's env (annotation-matched). Promotion = deploying the same Octopus release to the next env. Deploys into `argo-randomquotes-{source}-{tenant}-{env}` namespaces (separate prefix avoids collision with the agent path).
- **Empty-tag sentinel for Production:** `gitops/charts/randomquotes/values-{local,saas}-production.yaml` ships with `image.tag: ""`, and the chart's `deployment.yaml` is guarded `{{- if .Values.image.tag }} … {{- end }}`. Result: Production Applications render namespace + Service + Ingress + ConfigMap but **zero pods** until Octopus actually promotes a release to that env. The Octopus image-tag update step writes the real tag, the Deployment materialises on the next Argo sync. Keeps the Argo CD Instances panel honest (Octopus's promotion state = the cluster's deployment state).

The `OctopusDeploy/octopusdeploy` provider has zero Argo CD resources as of v1.12 — `tofu/modules/octopus-argocd-gateway/` placeholders the schema we'd hope they'll ship for the Gateway connection, so the eventual migration is "swap the implementation, keep the call sites".

## Editing rules of thumb

- **Don't redefine deployment process / variables / channels / runbooks in HCL.** They are owned by `.octopus/*.ocl`. Either edit OCL by hand and commit, or edit in the Octopus UI and let it commit.
- **Don't pre-populate `.octopus/`.** Let Octopus seed each file on first save so the schema matches the running server.
- **`MASTER_KEY` is generated once.** Changing it after first boot makes existing encrypted data unreadable.
- The `octopusdeploy` provider is `OctopusDeploy/octopusdeploy ~> 1.12` (the official one, not the older `OctopusDeployLabs/` fork). The k8s-agent stack additionally uses `helm` and `kubernetes` providers and requires Docker Desktop Kubernetes enabled.
- `gitops/charts/randomquotes/` is the source-of-truth Helm chart for the **GitOps path** (every leaf Application instantiates the chart with per-tenant values). Plain manifests in `app/` are not used by Argo. The K8s agent path is independent — its inlined OCL manifests live in `.octopus/deployment_process.ocl` and substitute Octopus variables at deploy time. Argo's path uses Helm values for the same per-tenant variation. Both paths target distinct namespaces (`argo-randomquotes-…` vs `randomquotes-…`) so they coexist on the same cluster.
- **Demo branches are 1 surgical commit on main.** Each open PR branch (`demo/*`, `feat/*`, `infra/ha`) carries only the files that demonstrate that feature: its own `.octopus-<demo>/` OCL, chart template overrides (`rollout.yaml`, `sealed-secret.yaml`), or stack additions (`tofu/platform-hub/policies/`, `tofu/servicenow/`). No drift on shared files (`Makefile`, `tofu/k8s-agent/`, `tofu/argocd/`, etc.). When main moves, rebase the branches (force-push-with-lease is authorised on them); don't push doc/infra updates to demo branches, push to main and let the next rebase carry them.
- **Process templates live in Platform Hub and use a different OCL schema than step templates** (`.octopus/process-templates/<slug>.ocl`). Gotchas burned in: (1) `default_value` is **not** on `ProcessTemplateParameter` — leaving the field out is fine, set defaults via the UI; (2) deferred packages must bind to a `Package`-typed parameter (`display_settings = { Octopus.ControlType = "Package" }`) via *three* things together — the `parameter` exists, the `packages "<Name>" { }` block name matches the parameter name, **and** `properties.PackageParameterName = "<Name>"` is set on the package block; matching block name alone is not enough (Octopus rejects with `Please select a package parameter for the package`). YAML references the package by parameter name: `#{Octopus.Action.Package[AppImage].Image}`; `feed` and `package_id` stay blank — the consuming project supplies them at instantiation. Cross-check by hitting `/api/communityactiontemplates` to see how working step templates serialize the binding. (3) `Octopus.Action.KubernetesContainers.AutoCreateNamespace = "True"` is accepted at the OCL layer on `KubernetesDeployRawYaml` even though the UI doesn't expose a toggle for that step type; (4) Platform Hub has no feeds endpoint — `/api/platformhub/feeds` is 404 — so the consuming Space's feeds resolve at instantiation time (every Space using a template needs a feed with the same slug, OR the template uses a Package-typed parameter so the project picks the feed).
- **REST endpoint to verify a process template parses without round-tripping the UI** (not advertised in the API root's Links list — found by watching `docker compose logs octopus` while the UI loads a template): `GET /api/platformhub/refs%2Fheads%2F{branch}/processtemplates/summaries` lists templates with a `HasError` flag, and `GET /api/platformhub/refs%2Fheads%2F{branch}/processtemplates/{slug}` returns the parsed template or HTTP 400 with the OCL error message body. Use this to gate template edits before merging.
