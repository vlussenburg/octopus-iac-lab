# tofu/platform-hub/

Wires Octopus Platform Hub at the Git repo that holds policy YAML.

| File | What it owns |
|------|--------------|
| [`main.tf`](main.tf) | Provider config |
| [`variables.tf`](variables.tf) | Inputs (PAT via `TF_VAR_github_pat`, repo coords from `defaults.auto.tfvars`) |
| [`version_control.tf`](version_control.tf) | `/api/platformhub/versioncontrol` — repo URL, branch, base path, inline PAT auth |
| [`git_credential.tf`](git_credential.tf) | `/api/platformhub/git-credentials` — PAT credential for Platform Hub features that perform Git ops |

The actual policy *content* (YAML files Platform Hub reads) is committed to this repo under `.octopus/` — not managed here.

## Optional

Gated by `OCTOPUS_PLATFORM_HUB_ENABLED` (default `true` in the Makefile). Set to `false` in `.env` if your target Octopus doesn't have Platform Hub (older self-host or some SaaS instances) — `make apply` will skip this stack and the rest still works.

## Run

```bash
make ph-init
make ph-plan
make ph-apply
```
