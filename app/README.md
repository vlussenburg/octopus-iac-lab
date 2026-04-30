# app/

The Random Quotes K8s sample app — the artefact Octopus deploys.

| File | Purpose |
|------|---------|
| [`Dockerfile`](Dockerfile) | nginx + static `index.html`, with a `VERSION` build-arg that gets baked into the page footer. Built + pushed to `ghcr.io/vlussenburg/octopus-iac-lab` by [`../.github/workflows/build.yml`](../.github/workflows/build.yml). |
| [`index.html`](index.html) | The actual page. Reads `/config.json` at startup for tenant/mood/icon/colour/watermark/maintenance overrides — that file is materialised by Octopus at deploy time via a ConfigMap. Honours a `maintenance` overlay used by the `Maintenance Mode On` runbook. |
| `k8s/` | **Stale.** Original namespace/deployment/service YAMLs. The deployment process now inlines its own manifests (Deployment + Service + Ingress + ConfigMap mount) in [`../.octopus/deployment_process.ocl`](../.octopus/deployment_process.ocl), so this folder isn't read by anything. Kept as a reference of the original octopus-ttc shape. |

## Build locally (optional)

```bash
docker build -t randomquotes:dev .
docker run --rm -p 8080:80 randomquotes:dev
open http://localhost:8080
```

## How Octopus uses this

[`../.octopus/deployment_process.ocl`](../.octopus/deployment_process.ocl) has two steps:

1. **Deploy ConfigMap** — `Octopus.KubernetesDeployConfigMap` writes `config.json` (tenant/mood/icon/colour/watermark + empty maintenance) into a ConfigMap named `randomquotes-config`.
2. **Deploy Manifests** — `Octopus.KubernetesDeployRawYaml` applies an inline Deployment (image pulled from the GHCR feed via the `randomquotes-image` package reference), Service, and Ingress for `#{Source}-#{tenant}-#{env}.localtest.me`. The ConfigMap is mounted into the pod at `/usr/share/nginx/html/config.json`.

The `Maintenance Mode On` runbook ([`../.octopus/runbooks/maintenance-on.ocl`](../.octopus/runbooks/maintenance-on.ocl)) patches the same ConfigMap with `maintenance = #{Maintenance.Message}` and scales the Deployment to 1 replica; `Maintenance Mode Off` clears the message and scales back to the tier's `#{Replicas}` value.
