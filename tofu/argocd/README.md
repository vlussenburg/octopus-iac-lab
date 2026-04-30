# tofu/argocd/

ArgoCD + Octopus Argo CD Gateway, plus six annotated Argo `Application`s — one per (tenant × env). Demonstrates Octopus's pull-based GitOps integration alongside the existing push-based K8s agent. Both deploy randomquotes; they don't collide because their namespace conventions differ:

|  | Source of truth | Namespace pattern | Triggered by |
|---|---|---|---|
| **K8s agent** ([`../k8s-agent/`](../k8s-agent/)) | Inline manifests in `.octopus/deployment_process.ocl` | `randomquotes-{source}-{tenant}-{env}` | Octopus release / runbook |
| **ArgoCD** (this stack) | `app/k8s/*.yaml` in this repo | `argo-randomquotes-{source}-{tenant}-{env}` | git commit (Argo polls), surfaced to Octopus via Gateway annotations |

## Why both?

Octopus's Argo CD integration uses annotations (`argo.octopus.com/project`, `.../environment`, `.../tenant`) on `Application` CRDs. The Gateway watches the cluster and reports those Applications back to Octopus, where they show up under Infrastructure → Argo CD Instances and become deployable from the same project as the agent-based path. So a single Octopus project can have both delivery styles attached, and you can pick per-step which one to use.

## File layout

| File | What it owns |
|------|--------------|
| [`main.tf`](main.tf) | Providers (octopusdeploy + helm + kubernetes + kubectl + argocd) and `terraform_remote_state` for space/cp/app |
| [`variables.tf`](variables.tf) | Inputs — chart versions, Octopus URL, optional gRPC URL override |
| [`argocd_install.tf`](argocd_install.tf) | argo-cd helm release. Configures the `octopus` account (apiKey-only) + RBAC policy. `configs.params.server.insecure=true` so argocd-server doesn't double-TLS behind nginx-ingress. |
| [`argocd_account.tf`](argocd_account.tf) | `argocd_account_token` resource mints a 30-day JWT for the `octopus` account. Materialised as a Kubernetes Secret in the gateway namespace; ditto the Octopus access token. |
| [`gateway_install.tf`](gateway_install.tf) | Octopus Argo CD Gateway helm release. Per-Octopus suffixed (`octopus-argo-gateway-{local,saas}`) — both worktrees can install gateways into the same cluster against different Octopi. |
| [`ingress.tf`](ingress.tf) | Ingress to the argo UI at `argocd.localtest.me:8080` via the cluster's nginx-ingress. |
| [`applications.tf`](applications.tf) | `module.randomquotes_argo_app` × 6 — instantiates the local `octopus-argocd-application` module once per (tenant × env). |
| [`outputs.tf`](outputs.tf) | URL, admin-password kubectl one-liner, application names |

## The local module: [`../modules/octopus-argocd-application/`](../modules/octopus-argocd-application/)

A placeholder for what we'd hope the `OctopusDeploy/octopusdeploy` provider eventually ships as `octopusdeploy_argocd_application`. Inputs are deliberately Octopus-flavoured (`octopus_project_slug`, `octopus_environment_slug`, `octopus_tenant_slug`) — when the real provider resource lands, the migration is mechanical: swap the `kubectl_manifest` body out for the resource, keep call sites unchanged.

The module renders an Argo `Application` with the right `argo.octopus.com/*` annotations so the Gateway claims it on Octopus's behalf. Avoids `null_resource` / `local-exec` — `kubectl_manifest` is the only "manifest" provider that doesn't validate CRD schemas at plan time, which matters here because the Argo CD CRDs only get created by the helm install in this same apply.

## Auth model

Two distinct tokens:

1. **Octopus API key** — the same `OCTOPUS_API_KEY` from `.env`. Used by the Gateway's registration init Job to POST a new "Argo CD Instance" record into Octopus via the HTTP API. Materialised into a `kubernetes_secret_v1` and referenced by the chart via `registration.octopus.serverAccessTokenSecretName`.
2. **ArgoCD JWT** — minted in-stack via `argocd_account_token` (oboukili/argocd v6 provider), 30-day TTL, auto-renewed when within 7d of expiry. Materialised similarly and consumed by the chart via `gateway.argocd.authenticationTokenSecretName`. The token belongs to the `octopus` account configured in argocd-cm with the documented minimum RBAC.

The `argocd` provider authenticates as admin during the apply via the auto-generated `argocd-initial-admin-secret`. It uses `port_forward_with_namespace` so no host-side `kubectl port-forward` is needed.

## Local self-host vs SaaS

The Gateway's outbound gRPC connection to Octopus needs a reachable endpoint:

- **SaaS**: defaults to `grpc://<id>.octopus.app:443` over the public LB's protocol-aware routing. Works out of the box.
- **Local self-host**: defaults to `grpc://host.docker.internal:8443`, which compose exposes — but the Octopus container serves a self-signed cert. The Gateway will reject that until you mount the cert as a Secret and point at it via `gateway.serverCertificateSecretName`. Override `OCTOPUS_GRPC_PLAINTEXT=true` if you have a plaintext-terminating proxy. Local-self-host gRPC connectivity is left as a TODO; the rest of the stack (ArgoCD, Applications, the JWT/token mint) all works fine — only the Octopus → Gateway link is bumpy.

## Run

After `make app-apply` (the project must exist for the Gateway registration to bind):

```bash
make argo-init
make argo-plan
make argo-apply
```

Verify:

```bash
kubectl get pods -n argocd
kubectl get pods -n octopus-argo-gateway
kubectl get applications -n argocd
# UI:
kubectl port-forward svc/ingress-nginx-controller 8080:8080 -n ingress-nginx
open http://argocd.localtest.me:8080
# admin password:
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

In Octopus: open Infrastructure → Argo CD Instances; you should see `argocd-{local,saas}` connected and the six Applications listed under it.

## Tear down

```bash
make argo-destroy
```

This `helm uninstall`s the Gateway and ArgoCD, deletes the Applications via `kubectl_manifest` finalizers, and removes the per-Octopus registration record. The shared cluster infra (NFS CSI, nginx-ingress) stays.
