# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project purpose

Personal lab for scaffolding a self-hosted Octopus Server entirely as code, with Config-as-Code (CaC) on from minute one. Project state lives in Git (`.octopus/*.ocl`) rather than the Octopus database. Sandbox only — not a reference for production.

## Common commands

All `make` targets run from the **repo root**. The Makefile loads `.env` once and re-exports `OCTOPUS_API_KEY` / `GITHUB_PAT` as `TF_VAR_*` for OpenTofu.

```bash
# Local Octopus Server (compose/)
make up | down | logs | ps | nuke   # nuke deletes volumes — wipes DB + master key

# Per-stack (cp = control-plane, app = app-randomquotes, agent = k8s-agent)
make {cp,app,agent}-{init,plan,apply,destroy,fmt,validate}

# Convenience
make fmt validate                   # all stacks
make apply                          # cp → app → agent (order matters; app/agent read cp state)
make destroy                        # reverse order
```

First-time bootstrap order: `make up` → log in at `localhost:8090` → mint API key + paste `compose/license.xml` via UI → fill `.env` → `make apply`.

## Architecture

### Three-layer split

1. **`compose/`** — docker-compose runtime (SQL Server 2022 + Octopus Server, both pinned `linux/amd64`). Host port `8090`. Reads `MASTER_KEY` from `.env`. License is *not* mounted — pasted via UI after first boot.
2. **`tofu/`** — three independent OpenTofu stacks, each with its own local `terraform.tfstate`. They are intentionally split, not modules.
3. **`.octopus/`** — OCL files owned by Octopus. Once the CaC project exists, Octopus serialises deployment process / settings / variables / runbooks here on every UI save and commits via the configured Git credential. **Folder name is fixed** — Octopus rejects anything other than `.octopus`.

### Cross-stack state sharing

`app-randomquotes` and `k8s-agent` read `control-plane` outputs via `terraform_remote_state` with `backend = "local"` pointing at `../control-plane/terraform.tfstate`. This is why apply order is enforced (`cp` → `app`/`agent`) and why splitting the state files matters: a noisy app-side plan never threatens shared infra.

| Stack | Owns |
|---|---|
| `tofu/control-plane/` | Environments (Dev/Production), lifecycle, project group, GitHub PAT Git credential |
| `tofu/app-randomquotes/` | The `randomquotes` project resource only — `is_version_controlled = true` with `git_library_persistence_settings` pointing at this repo's `.octopus/`. Deployment process is **not** declared in HCL; it lives in `.octopus/deployment_process.ocl`. |
| `tofu/k8s-agent/` | NFS CSI driver + Octopus K8s Agent Helm release. Self-registers as a deployment target tagged with role `k8s` (which `deployment_process.ocl` targets) bound to Dev + Production. |

### Secrets vs config split

- `.env` (gitignored): `MASTER_KEY`, `OCTOPUS_API_KEY`, `GITHUB_PAT`. Nothing else.
- `tofu/<stack>/defaults.auto.tfvars` (committed): non-sensitive lab values (Octopus URL, space, CaC repo URL/branch/base path, agent name, chart version, etc.).
- The Makefile is the only thing that bridges `.env` → `TF_VAR_*`. Don't add `terraform.tfvars` files for these.

### Auth model (lab-only choices)

- **Octopus → GitHub (CaC commits)**: GitHub PAT with `repo` scope, stored as an Octopus Git credential created in `control-plane`.
- **K8s agent → Octopus**: admin API key passed as `agent.bearerToken` in the Helm chart. Octopus accepts API keys as `Authorization: Bearer`. Replace with a scoped service-account key for anything non-sandbox.
- **KLOS / kubernetes monitor**: deliberately disabled — would require exposing gRPC `8443` from the compose stack.

### Compose quirks worth knowing

- Host port is **8090** (not 8080) because 8080 is reserved for an ArgoCD port-forward on this machine.
- Both images forced to `linux/amd64`; enable Docker Desktop "Use Rosetta" on Apple Silicon.
- Polling tentacle port is `host.docker.internal:10943` (Halibut, TLS over TCP) — different from the HTTP API.

## Editing rules of thumb

- **Don't redefine deployment process / variables / channels / runbooks in HCL.** They are owned by `.octopus/*.ocl`. Either edit OCL by hand and commit, or edit in the Octopus UI and let it commit.
- **Don't pre-populate `.octopus/`.** Let Octopus seed each file on first save so the schema matches the running server.
- **`MASTER_KEY` is generated once.** Changing it after first boot makes existing encrypted data unreadable.
- The `octopusdeploy` provider is `OctopusDeployLabs/octopusdeploy ~> 0.43`. The k8s-agent stack additionally uses `helm` and `kubernetes` providers and requires Docker Desktop Kubernetes enabled.
