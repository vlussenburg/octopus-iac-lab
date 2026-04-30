# tofu/

Five OpenTofu stacks, each with its own state. Non-sensitive lab config (space name, CaC repo, etc.) lives in committed `defaults.auto.tfvars` per stack. Sensitive values (API key, GitHub PAT, Octopus URL) come in via `TF_VAR_*` from the root `.env`.

| Stack | Owns | Why separate |
|-------|------|--------------|
| [`space/`](space/) | The non-default `IaC Sandbox` Space (slug pinned `iac-sandbox`) | Kill-switch. Destroying this cascades through every project, env, lifecycle, target inside. |
| [`control-plane/`](control-plane/) | Environments, lifecycle, project group, GHCR feed, library variable set, tenants + tags + tenant logos, GitHub PAT credential | Shared infra. Apply once, leave alone. |
| [`platform-hub/`](platform-hub/) | Octopus Platform Hub Git wiring (versioncontrol + git-credentials) | Optional — gated by `OCTOPUS_PLATFORM_HUB_ENABLED` so SaaS targets without the feature can opt out. |
| [`app-randomquotes/`](app-randomquotes/) | The `randomquotes` project (CaC-enabled, tenanted) | App-specific. Reads control-plane outputs via `terraform_remote_state`. |
| [`k8s-agent/`](k8s-agent/) | NFS CSI driver + nginx-ingress controller + Octopus K8s Agent helm release | Cluster-side install. Independent — useful to apply/destroy without touching the project. Also reads control-plane state. |

Apply order is enforced by the Makefile:

```bash
make space-apply     # the Space (kill-switch)
make cp-apply        # control-plane (envs, lifecycle, tenants, etc.)
make ph-apply        # platform-hub (skip if OCTOPUS_PLATFORM_HUB_ENABLED=false)
make app-apply       # randomquotes project
make agent-apply     # K8s agent + shared cluster infra (needs Docker Desktop K8s enabled)
```

Or all in one:

```bash
make apply           # space → cp → ph → app → agent
```

## Cross-stack state sharing

Each stack has its own `terraform.tfstate` (local backend). Downstream stacks read upstream outputs via:

```hcl
data "terraform_remote_state" "space" {
  backend = "local"
  config  = { path = "../space/terraform.tfstate" }
}
```

`control-plane`, `platform-hub`, `app-randomquotes`, and `k8s-agent` all bind their `octopusdeploy` provider's `space_id` to the Space stack's output, so the destroy of `space` cleans up everything they created inside it. `app` and `agent` additionally read `control-plane` for env/lifecycle/project-group/library-variable-set IDs.

## Why split into stacks?

- **space** is the kill switch. One `tofu destroy` here nukes everything in the Space — useful for SaaS where there's no `make nuke` equivalent.
- **control-plane** is boring + stable. Apply once, then ignore.
- **platform-hub** is optional + Octopus-version-sensitive. Splitting it lets the lab work on SaaS instances that don't have Platform Hub.
- **app-randomquotes** is what the team iterates on (channels, variables, runbooks via OCL). Splitting it from infra means a noisy `tofu plan` on the app side never threatens the shared layer.
- **k8s-agent** is cluster-side, independent of Octopus project work, and needs different providers (helm + kubernetes). Keeping it separate also makes it easy to nuke + reinstall the agent without disturbing project state.
