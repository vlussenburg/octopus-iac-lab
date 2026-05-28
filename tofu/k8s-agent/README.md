# tofu/k8s-agent/

Installs the **Octopus Kubernetes Agent** + shared cluster infra (NFS CSI driver, nginx-ingress controller) into a local K8s cluster (Docker Desktop by default) via Helm. The agent self-registers as a deployment target tagged `k8s` in environments `Dev` + `Production`, with tenant participation set so every tenant can deploy through it. The role is what [`../../.octopus/deployment_process.ocl`](../../.octopus/deployment_process.ocl) and the runbooks target.

| File | What it owns |
|------|--------------|
| [`main.tf`](main.tf) | Provider config (octopus + helm + kubernetes) and `terraform_remote_state` for the Space and control-plane |
| [`variables.tf`](variables.tf) | Inputs (kube context, agent name, server URL from cluster's POV, etc.) |
| [`nfs_csi.tf`](nfs_csi.tf) | NFS CSI driver helm release (`csi-driver-nfs` in `kube-system`). `helm upgrade --install` so it survives `make agent-destroy` and serves any other agents on the cluster. |
| [`nginx_ingress.tf`](nginx_ingress.tf) | nginx-ingress controller helm release (`ingress-nginx` in `ingress-nginx`). Same survive-destroy pattern. Means one `kubectl port-forward svc/ingress-nginx-controller 8080:8080` covers every tenant×env via `*.localtest.me`. |
| [`agent_install.tf`](agent_install.tf) | A `kubernetes_namespace_v1` for the agent + the `helm_release` for `octopusdeploy/kubernetes-agent`. KLOS (kubernetes-monitor) on — `machineName` points at the agent's own machine so the monitor binds to that target and streams live object status; gRPC dials `host.docker.internal:18443` (compose maps it to the container's `:8443`) pinned by the live cert thumbprint. |
| [`argo_rollouts.tf`](argo_rollouts.tf) | Argo Rollouts controller (`argo-rollouts` in `argo-rollouts`). Shared cluster infra so the BG / canary demo branches don't each have to install it. Survives `make agent-destroy`. |
| [`sealed_secrets.tf`](sealed_secrets.tf) | Sealed Secrets controller install with key-restore / key-save `null_resource`s — mirrors the active keypair to `.env` as `SEALED_SECRETS_TLS_B64` so cluster resets keep decrypting existing SealedSecrets. |
| [`deregister.tf`](deregister.tf) | Destroy-time `null_resource` that DELETEs the registered deployment target out of Octopus before `helm uninstall` runs. Without this, the orphaned target blocks env deletion later. |
| [`outputs.tf`](outputs.tf) | Convenience kubectl command + helm release info |

## Auth: admin API key as bearer

Octopus accepts API keys as `Authorization: Bearer ...`, so we feed the existing `OCTOPUS_API_KEY` directly to `agent.bearerToken`. No service-account dance, no minting, no extra resources. **Fine for a localhost lab; wrong for anything real**, where you'd want a scoped service-account API key (or a one-time registration token from the UI flow that this provider doesn't yet model).

## Prerequisites

- **Docker Desktop K8s enabled** — Settings → Kubernetes → Enable. Tofu's `kubernetes` provider needs a working `~/.kube/config` context (default `docker-desktop`).
- The space + control-plane stacks applied first (`make space-apply && make cp-apply`) — this stack reads both.
- Local Octopus reachable from inside K8s pods at `http://host.docker.internal:8090`. Docker Desktop K8s resolves that hostname out of the box. SaaS just uses its own URL.

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

This `helm uninstalls` the agent + cleans up the registered deployment target via the destroy-time `null_resource`. The shared NFS CSI driver and nginx-ingress controller are deliberately **not** destroyed — they live in `kube-system` / `ingress-nginx` and can serve other agents on the cluster. Remove them explicitly when tearing the cluster down (see the root README's "Wiping the lab" section).
