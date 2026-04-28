# tofu/k8s-agent/

Installs the **Octopus Kubernetes Agent** into a local K8s cluster (Docker Desktop by default) via Helm. The agent self-registers as a deployment target tagged `k8s` in environments `Dev` + `Production` — picked up by the deployment step in [`../../.octopus/deployment_process.ocl`](../../.octopus/deployment_process.ocl).

| File | What it owns |
|------|--------------|
| [`main.tf`](main.tf) | Provider config (octopus + helm + kubernetes) and `terraform_remote_state` for control-plane outputs |
| [`variables.tf`](variables.tf) | Inputs (kube context, agent name, server URL from cluster's POV, etc.) |
| [`agent_install.tf`](agent_install.tf) | The `helm_release` for `octopusdeploy/kubernetes-agent`. KLOS toggle off (compose doesn't expose gRPC port 8443). |
| [`outputs.tf`](outputs.tf) | Convenience kubectl command + helm release info |

## Auth: admin API key as bearer

Octopus accepts API keys as `Authorization: Bearer ...` — so we feed the existing `OCTOPUS_API_KEY` directly to `agent.bearerToken`. No service-account dance, no minting, no extra resources. **This is fine for a localhost lab; it'd be wrong for anything real**, where you'd want a scoped service-account API key (or a one-time registration token from the UI flow that this provider doesn't yet model).

## Prerequisites

- **Docker Desktop K8s enabled** — Settings → Kubernetes → Enable. Tofu's `kubernetes` provider needs a working `~/.kube/config` context (default `docker-desktop`).
- The control-plane stack applied first (`make cp-apply`) — this stack reads its outputs.
- Local Octopus reachable from inside K8s pods at `http://host.docker.internal:8090`. Docker Desktop K8s resolves that hostname out of the box.

No need to install `helm` separately — tofu's `helm` provider has it embedded.

## Run

```bash
make agent-init
make agent-plan
make agent-apply
```

Verify:

```bash
kubectl get pods -n octopus-agent-docker-desktop
# Open the Infrastructure → Deployment Targets page in Octopus
```

## Tear down

```bash
make agent-destroy
```

Note: this only does `helm uninstall`. The deployment target Octopus registered remains in Octopus state — clean it up manually via the UI or the API. (Adoption into tofu state is hard because the target's thumbprint/uri are only known post-registration; left as a future improvement.)
