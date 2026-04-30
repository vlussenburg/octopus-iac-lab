# tofu/space/

Creates the non-default Space everything else in the lab lives inside. The Space is the kill switch — `tofu destroy` here cascades through Octopus and removes every project, env, lifecycle, credential, and target inside it.

| File | What it owns |
|------|--------------|
| [`main.tf`](main.tf) | Provider config (bound to `Spaces-1` so we can *create* the new Space) |
| [`variables.tf`](variables.tf) | Inputs (URL/key from `.env`; name from `defaults.auto.tfvars`) |
| [`space.tf`](space.tf) | The `octopusdeploy_space` resource. Slug pinned to `iac-sandbox` so CI references stay valid across destroy/recreate (the auto-generated `Spaces-N` ID increments every time). Both `teams-administrators` and `teams-managers` listed as Space managers (the bootstrap user lives in different teams on local self-host vs SaaS — listing both works on both targets). |

Downstream stacks (`control-plane`, `platform-hub`, `app-randomquotes`, `k8s-agent`) consume `space_id` from this stack via `terraform_remote_state` and bind their own provider to it.

## Run

```bash
make space-init
make space-plan
make space-apply
```

## Nuke

```bash
make destroy   # full reverse chain: agent → app → ph → cp → space
# or just this stack:
make space-destroy
```
