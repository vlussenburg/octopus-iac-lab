# tofu/control-plane/

Shared Octopus infra. Apply once, then largely leave alone.

| File | What it owns |
|------|--------------|
| [`main.tf`](main.tf) | Provider config |
| [`variables.tf`](variables.tf) | Inputs (fed via `TF_VAR_*` from the root `Makefile`) |
| [`environments.tf`](environments.tf) | `Dev` and `Production` |
| [`lifecycle.tf`](lifecycle.tf) | `Dev → Production` |
| [`project_group.tf`](project_group.tf) | `IaC Lab` project group |
| [`git_credential.tf`](git_credential.tf) | GitHub PAT credential Octopus uses for CaC |
| [`outputs.tf`](outputs.tf) | IDs the app stack needs (consumed via `terraform_remote_state`) |

## Run

From the repo root:

```bash
make cp-init
make cp-plan
make cp-apply
```
