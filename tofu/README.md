# tofu/

Declarative scaffold for the local Octopus Server using **OpenTofu** (the open-source fork of Terraform). One file per resource type so the layout is its own table of contents.

| File | What it owns |
|------|--------------|
| [`main.tf`](main.tf) | `OctopusDeployLabs/octopusdeploy` provider + `terraform` block |
| [`variables.tf`](variables.tf) | All input variables (fed via `TF_VAR_*` from the root `Makefile`) |
| [`environments.tf`](environments.tf) | `Dev` and `Production` environments |
| [`lifecycle.tf`](lifecycle.tf) | `Dev → Production` lifecycle |
| [`project_group.tf`](project_group.tf) | `IaC Lab` project group |
| [`git_credential.tf`](git_credential.tf) | Octopus-side Git credential (PAT-based) used for CaC |
| [`project.tf`](project.tf) | The version-controlled project — flips Octopus into CaC mode for itself |
| [`outputs.tf`](outputs.tf) | Useful URLs/IDs after `apply` |

## Why OpenTofu, not Terraform

After Hashicorp's BSL re-licence, `terraform` was pulled from `homebrew-core`. OpenTofu is the community-stewarded fork — drop-in compatible with `.tf` syntax and with the `OctopusDeployLabs/octopusdeploy` provider. Binary is `tofu`. The `.tf` extension stays.

## Run it

From the repo root (not this folder):

```bash
make init      # one-time
make plan
make apply
```

The Makefile sources `../.env`, exports `TF_VAR_*`, then `cd`s in here. Running `tofu` directly works too — set `TF_VAR_*` yourself, or drop a `terraform.tfvars` (gitignored).

## State

Local backend on purpose — this is a sandbox and the state is recreatable. If the lab grows teeth, move state to a remote backend before any second human touches it.
