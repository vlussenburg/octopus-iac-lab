# tofu/

Two OpenTofu stacks, applied in order:

| Stack | Owns | Why separate |
|-------|------|--------------|
| [`control-plane/`](control-plane/) | Environments, lifecycle, project group, Git credential | Shared infra — applied once, then ignored. Re-running won't churn app config. |
| [`app-randomquotes/`](app-randomquotes/) | The `randomquotes` project (CaC-enabled) | App-specific. Reads control-plane outputs via `terraform_remote_state`. |

Apply order matters: `control-plane` first, `app-randomquotes` second.

```bash
make cp-apply       # applies tofu/control-plane/
make app-apply      # applies tofu/app-randomquotes/
```

Each stack has its own `terraform.tfstate` (local backend). The app stack reads control-plane state via:

```hcl
data "terraform_remote_state" "control_plane" {
  backend = "local"
  config  = { path = "../control-plane/terraform.tfstate" }
}
```

## Why split?

The control-plane is **boring and stable** — once it's right, you don't touch it. The app stack is **what the team iterates on** — adding projects, channels, variables. Splitting them means a noisy `tofu plan` on the app side never threatens the shared infra below it. It's also how customers tend to organise this in real Octopus + CaC setups.
