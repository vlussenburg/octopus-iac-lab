# tofu/app-randomquotes/

The `randomquotes` Octopus project — the application-level scaffold. Mimics the equivalent project from `octopus-ttc`, but every config artefact lives in this repo (no UI, no setup script).

| File | What it owns |
|------|--------------|
| [`main.tf`](main.tf) | Provider config + `terraform_remote_state` data source pointing at `../control-plane/terraform.tfstate` |
| [`variables.tf`](variables.tf) | Inputs (fed via `TF_VAR_*` from the root `Makefile`) |
| [`project.tf`](project.tf) | The version-controlled `randomquotes` project. References env/lifecycle/git-cred IDs from control-plane outputs. |
| [`outputs.tf`](outputs.tf) | Project URL + ID for convenience |

## What's NOT here

- **Deployment process** — lives in [`../../.octopus/deployment_process.ocl`](../../.octopus/) (CaC-managed by Octopus).
- **K8s manifests** — live in [`../../app/k8s/`](../../app/k8s/) and are referenced by the deployment step.
- **Image / Dockerfile** — lives in [`../../app/`](../../app/). Image deployed is `octopussamples/randomquotes-k8s` for now (public sample); swap for a private build pipeline later.

## Run

From the repo root, after `make cp-apply`:

```bash
make app-init
make app-plan
make app-apply
```
