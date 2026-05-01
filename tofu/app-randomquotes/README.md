# tofu/app-randomquotes/

The `randomquotes` Octopus project — the application-level scaffold. Tenanted, CaC-enabled, and reads everything else from `control-plane` outputs.

| File | What it owns |
|------|--------------|
| [`main.tf`](main.tf) | Provider config + `terraform_remote_state` data sources for the Space and control-plane |
| [`variables.tf`](variables.tf) | Inputs (fed via `TF_VAR_*` from the root `Makefile`) |
| [`project.tf`](project.tf) | The `randomquotes` project. `is_version_controlled = true`, `tenanted_deployment_participation = "Tenanted"`, `git_library_persistence_settings` pointing at this repo's `.octopus/`. Includes the `Lab Defaults` library variable set. Linked to the three tenants via `octopusdeploy_tenant_project`. |
| [`outputs.tf`](outputs.tf) | Project URL + ID for convenience |

## What's NOT here

- **Deployment process** — lives in [`../../.octopus/deployment_process.ocl`](../../.octopus/deployment_process.ocl) (CaC-managed by Octopus). Inlines the K8s manifests (Deployment + Service + Ingress) and a ConfigMap step.
- **Runbooks** — live in [`../../.octopus/runbooks/`](../../.octopus/runbooks/) (`maintenance-on.ocl`, `maintenance-off.ocl`).
- **Project variables** — live in [`../../.octopus/variables.ocl`](../../.octopus/) alongside the deployment process.
- **Image build** — happens in [`.github/workflows/build.yml`](../../.github/workflows/build.yml). Image is `ghcr.io/vlussenburg/octopus-iac-lab` (built from this repo's [`app/Dockerfile`](../../app/Dockerfile)), pulled via the GHCR feed registered in `control-plane`.
- **K8s manifests as files** — packaged as a helm chart in [`../../gitops/charts/randomquotes/`](../../gitops/charts/randomquotes/) and instantiated 12 times by the leaf Applications under `gitops/applications/randomquotes/{local,saas}/`. Each leaf supplies its own `helm.valuesObject` for tenant/mood/icon/color/host/replicas. The deployment process OCL inlines its own manifests for the K8s agent path; the gitops/ tree is the source for the Argo path.

## Run

From the repo root, after `make space-apply` and `make cp-apply`:

```bash
make app-init
make app-plan
make app-apply
```
