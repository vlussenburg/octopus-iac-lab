# tofu/argocd/

Minimum-footprint stack — owns only the **control plane** of the
Octopus ↔ Argo CD connection. Everything else (the App-of-Apps roots, the
argocd-server Ingress, the 12 per-tenant Application leaves) lives in
[`/gitops/`](../../gitops/) and is reconciled by Argo from git, not from
terraform state.

|  | Where it lives | Owned by |
|---|---|---|
| ArgoCD helm install (cluster-side prereq) | tofu (gated `install_argocd`) | local worktree |
| ArgoCD JWT for the `octopus` account | tofu (`argocd_account_token`) | per-worktree |
| Octopus Argo CD Gateway (the actual control plane) | tofu (`module.gateway`) | per-worktree |
| Bootstrap Application (helm `extraObjects`) | tofu, but as YAML inside helm values | local worktree |
| Argo `Application` roots (App-of-Apps) | [`gitops/argocd/randomquotes-root-{local,saas}.yaml`](../../gitops/argocd/) | git |
| argocd-server UI Ingress | [`gitops/argocd/argocd-server-ingress.yaml`](../../gitops/argocd/) | git |
| 12 leaf Argo `Application`s (per tenant×env) | [`gitops/applications/randomquotes/{local,saas}/*.yaml`](../../gitops/applications/) | git |

## Comparison with the K8s agent path

|  | Source of truth | Materialised by | Namespace pattern | Triggered by |
|---|---|---|---|---|
| **K8s agent** ([`../k8s-agent/`](../k8s-agent/)) | Inline manifests in `.octopus/deployment_process.ocl` | Octopus runtime (push) | `randomquotes-{source}-{tenant}-{env}` | Octopus release / runbook |
| **ArgoCD** (this stack) | `gitops/k8s/{dev,production}/*.yaml` | Argo CD (pull) | `argo-randomquotes-{source}-{tenant}-{env}` | git commit |

Both surface to the same Octopus project. Adding/changing a leaf Application is a one-file commit under `gitops/`; the gateway pod forwards the change events to Octopus.

## File layout

| File | What it owns |
|------|--------------|
| [`main.tf`](main.tf) | Providers (octopusdeploy + helm + kubernetes + argocd) and `terraform_remote_state` for space/cp/app |
| [`variables.tf`](variables.tf) | Inputs — chart versions, Octopus URL, optional gRPC URL override, `install_argocd` toggle |
| [`argocd_install.tf`](argocd_install.tf) | argo-cd helm release (count-gated by `install_argocd` — local owns it, SaaS piggybacks). Configures the `octopus` account (apiKey-only) + RBAC policy. `extraObjects` seeds a single `argocd-bootstrap` Application that syncs `gitops/argocd/`. |
| [`argocd_account.tf`](argocd_account.tf) | `argocd_account_token` resource mints a 30-day JWT for the `octopus` account. |
| [`gateway.tf`](gateway.tf) | Calls the local `../modules/octopus-argocd-gateway` module — that's the control-plane abstraction. |
| [`outputs.tf`](outputs.tf) | URL, admin-password kubectl one-liner, gateway name + namespace |

## The local module: [`../modules/octopus-argocd-gateway/`](../modules/octopus-argocd-gateway/)

Placeholder for what we'd hope the `OctopusDeploy/octopusdeploy` provider eventually ships as `octopusdeploy_argocd_gateway`. Inputs are deliberately Octopus-flavoured (`name`, `octopus_space_id`, `environments`) — when the real provider resource lands, the migration is mechanical: swap helm_release + secrets + null_resource for the resource, keep the variable surface intact.

## Auth model

Two distinct tokens:

1. **Octopus API key** — the `OCTOPUS_API_KEY` from `.env`. Used by the Gateway's registration init Job to POST a new "Argo CD Instance" record into Octopus's HTTP API, and by the destroy-time `null_resource` to DELETE that record on `agent-destroy`.
2. **ArgoCD JWT** — minted in-stack via `argocd_account_token` (oboukili/argocd v6 provider), 30-day TTL, auto-renewed when within 7d of expiry. Belongs to the `octopus` account configured in argocd-cm.

The `argocd` provider authenticates as admin via the auto-generated `argocd-initial-admin-secret`. It uses `port_forward_with_namespace` so no host-side `kubectl port-forward` is needed.

> **Provider quirk**: the v6 argocd provider sometimes can't read sensitive values from `data.kubernetes_secret_v1` reliably during apply (returns null even when the value is present). Workaround: `export ARGOCD_AUTH_USERNAME=admin ARGOCD_AUTH_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)` before `tofu apply`.

## Two-worktree symmetry

ArgoCD itself is shared cluster infra — only one worktree owns the helm release. By default the local worktree installs it; the saas worktree skips with `install_argocd = false` and reads the same admin secret. Override per-stack with `TF_VAR_install_argocd=true|false` if you want to flip ownership.

Per-Octopus things are suffixed `local` / `saas` so both worktrees coexist:
- Gateway helm release: `octopus-argo-gateway-{local,saas}`
- Gateway namespace: `octopus-argo-gateway-argocd-{local,saas}`
- App-of-Apps root names: `randomquotes-root-{local,saas}` (in `gitops/argocd/`)
- Argo Application names: `randomquotes-{tenant}-{env}-{local,saas}` (in `gitops/applications/`)
- Argo destination namespaces: `argo-randomquotes-{local,saas}-{tenant}-{env}`

## Run

After `make app-apply`:

```bash
make argo-init
make argo-plan
make argo-apply
```

If `argo-apply` complains about ArgoCD provider authentication ("either username/password or auth_token must be specified"), export the admin password as env vars first — see the Provider quirk note above.

Verify:

```bash
kubectl get pods -n argocd
kubectl get pods -n octopus-argo-gateway-argocd-local
kubectl get applications -n argocd       # should show 1 bootstrap + 2 roots + 12 leaves
# UI:
kubectl port-forward svc/ingress-nginx-controller 8080:8080 -n ingress-nginx
open http://argocd.localtest.me:8080
# admin password:
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

In Octopus: open Infrastructure → Argo CD Instances; you should see `argocd-{local,saas}` connected and the six Applications listed under it.

## Tear down

```bash
make argo-destroy
```

This `helm uninstall`s the Gateway and ArgoCD, deletes the registered Argo CD Instance via the destroy-time `null_resource`, and removes everything in `argocd` namespace by extension. The shared cluster infra (NFS CSI, nginx-ingress) stays.
