# tofu/control-plane/

Shared Octopus infra inside the Space. Apply once after `space-apply`, then largely leave alone.

| File | What it owns |
|------|--------------|
| [`main.tf`](main.tf) | Provider config + `terraform_remote_state` for the Space |
| [`variables.tf`](variables.tf) | Inputs (fed via `TF_VAR_*` from the root `Makefile`) |
| [`environments.tf`](environments.tf) | `Dev` and `Production` |
| [`lifecycle.tf`](lifecycle.tf) | `Dev → Production` |
| [`project_group.tf`](project_group.tf) | `IaC Lab` project group |
| [`feeds.tf`](feeds.tf) | GHCR external feed (`ghcr.io`) for the `vlussenburg/octopus-iac-lab` image |
| [`library_variables.tf`](library_variables.tf) | `Lab Defaults` library variable set — carries `Source = local|saas` (per-Octopus), `Replicas`, brand defaults, etc. Included on the project. |
| [`tenants.tf`](tenants.tf) | Three tenants (`acme-corp`, `globex`, `initech`) + tag sets (`tier/{free,pro,enterprise}`, `mood/{comedy,silicon-valley,stoic}`, `app/randomquotes`) + per-tenant variables (brand colour/icon, mood, replicas) |
| [`tenant_logos.tf`](tenant_logos.tf) | Uploads brand-coloured PNG logos to each tenant via `null_resource` + curl POST to `/api/{space}/tenants/{id}/logo` (the provider doesn't expose a logo attribute). Retriggers on file SHA. |
| [`git_credential.tf`](git_credential.tf) | GitHub PAT credential Octopus uses for CaC commits |
| [`outputs.tf`](outputs.tf) | IDs the app + agent stacks read via `terraform_remote_state` |

## Run

From the repo root:

```bash
make cp-init
make cp-plan
make cp-apply
```
