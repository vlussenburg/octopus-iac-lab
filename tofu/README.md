# tofu/

Three OpenTofu stacks, each with its own state. Non-sensitive lab config (Octopus URL, CaC repo, etc.) lives in committed `defaults.auto.tfvars` per stack. Sensitive values (API key, GitHub PAT) come in via `TF_VAR_*` from the root `.env`.

| Stack | Owns | Why separate |
|-------|------|--------------|
| [`control-plane/`](control-plane/) | Environments, lifecycle, project group, GitHub PAT credential | Shared infra. Apply once, leave alone. |
| [`app-randomquotes/`](app-randomquotes/) | The `randomquotes` project (CaC-enabled) | App-specific. Reads control-plane outputs via `terraform_remote_state`. |
| [`k8s-agent/`](k8s-agent/) | NFS CSI driver + Octopus K8s Agent helm release | Cluster-side install. Independent — useful to apply/destroy without touching the project. Also reads control-plane state. |

Apply order:

```bash
make cp-apply        # control-plane (envs, lifecycle, etc.)
make app-apply       # randomquotes project
make agent-apply     # K8s agent (needs Docker Desktop K8s enabled)
```

Or all in one:

```bash
make apply           # cp → app → agent
```

## Cross-stack state sharing

Each stack has its own `terraform.tfstate` (local backend). The app + agent stacks read control-plane state via:

```hcl
data "terraform_remote_state" "control_plane" {
  backend = "local"
  config  = { path = "../control-plane/terraform.tfstate" }
}
```

## Why three stacks?

- **control-plane** is boring + stable. Apply once, then ignore.
- **app-randomquotes** is what the team iterates on (channels, variables, etc.). Splitting it from infra means a noisy `tofu plan` on the app side never threatens the shared layer.
- **k8s-agent** is cluster-side, independent of Octopus project work, and needs different providers (helm + kubernetes). Keeping it separate also makes it easy to nuke + reinstall the agent without disturbing project state.
