# octopus-iac-lab

Personal lab: **Octopus Deploy** scaffolded entirely as code with **Config-as-Code** on. Same OCL + tofu drives a self-hosted Octopus and an Octopus Cloud SaaS instance from sibling worktrees, plus a tenant-aware K8s agent path AND a parallel Argo CD GitOps path so you can A/B the two delivery models from one project.

## Layout

```
compose/   # docker-compose Octopus Server (local worktree only)
tofu/      # 6 OpenTofu stacks: space → cp → ph → app → agent → argocd + a local module
.octopus/  # CaC-owned OCL: deployment process, runbooks, variables
gitops/    # Argo's source of truth: App-of-Apps roots + 12 leaf Applications + helm chart
app/       # Dockerfile + index.html (the deployed artefact)
assets/    # tenant logos uploaded by control-plane
```

Each folder has its own `README.md`. Non-sensitive lab config lives in committed `tofu/<stack>/defaults.auto.tfvars`; secrets in `.env` (gitignored).

## Bootstrap

```bash
cp .env.example .env       # fill in MASTER_KEY, OCTOPUS_URL, OCTOPUS_API_KEY, GITHUB_PAT
make up                    # local self-host only — boots compose stack on :8090
make apply                 # space → cp → ph → app → agent → argo
```

`make apply`'s first step (`ensure-api-key`) probes `.env`'s `OCTOPUS_API_KEY` against `/api/users/me` and auto-mints a fresh one on local self-host if it's stale (e.g. after `make nuke`). On SaaS, mint manually via the UI — keys can't be created without a browser session.

For the licence: base64 your XML (`base64 -i license.xml | tr -d '\n'`) and set as `OCTOPUS_SERVER_BASE64_LICENSE` in `.env` before `make up`. Otherwise paste in the UI after first login.

## Two delivery paths

`randomquotes` deploys to the same cluster two ways simultaneously, into different namespace prefixes:

| | Source of truth | Triggered by | Namespaces |
|---|---|---|---|
| **K8s agent (push)** | inlined manifests in `.octopus/deployment_process.ocl` | Octopus release | `randomquotes-{worktree}-{tenant}-{env}` |
| **Argo CD (pull)** | helm chart in `gitops/charts/randomquotes/`, instantiated 12× by leaves under `gitops/applications/` | Argo polls git, Octopus annotation-step bumps `image.tag` | `argo-randomquotes-{worktree}-{tenant}-{env}` |

`tofu/argocd/` is minimum-footprint: it only owns the control plane (ArgoCD install, JWT, Octopus Argo CD Gateway). Roots, leaves, ingress, and chart all live in `gitops/`.

## Reaching it

```bash
kubectl port-forward svc/ingress-nginx-controller 8080:8080 -n ingress-nginx
open http://local-acme-corp-dev.localtest.me:8080         # K8s agent path
open http://argo-local-acme-corp-dev.localtest.me:8080    # Argo path, same tenant
open http://argocd.localtest.me:8080                       # Argo UI
```

`*.localtest.me` resolves to 127.0.0.1, so no /etc/hosts edits.

## CI

- **`build.yml`** — push to `app/**` builds + pushes the image to GHCR, then calls `release.yml` as a workflow_call.
- **`release.yml`** — reusable, fans out by matrix to SaaS + Local Octopus. Creates the release with both packages pinned to the just-built tag and deploys tenanted to Dev. Promotion to Prod is via the Octopus UI (or another `release.yml` run targeting Prod), which also fires the Argo image-tag step on prod's leaves.

GitHub Actions secrets needed: `OCTOPUS_{SAAS,LOCAL}_{URL,API_KEY}`. Local target is `continue-on-error: true` — pipeline still passes if your laptop is offline. Expose local Octopus to GHA via Tailscale Funnel: `tailscale funnel --bg --https=443 http://localhost:8090` and put the printed URL into `OCTOPUS_LOCAL_URL`.

## Wiping the lab

| Scope | Command |
|---|---|
| Tofu-managed Octopus state (Space + everything in it) | `make destroy` |
| Plus local Octopus DB | `make destroy && make nuke` |
| Plus shared cluster infra (NFS CSI, nginx-ingress, ArgoCD) | `helm uninstall csi-driver-nfs -n kube-system && helm uninstall ingress-nginx -n ingress-nginx && helm uninstall argocd -n argocd` |

Cluster-side helm releases are deliberately destroy-survivors (installed via `helm upgrade --install`) so multiple worktrees / agents can share the cluster.

## Not in scope

Production guidance. This is a sandbox — auth choices, lab semantics, and "how would I demo X" trump anything resembling hardening.
