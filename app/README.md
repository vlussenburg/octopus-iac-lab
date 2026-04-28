# app/

The Random Quotes K8s sample app — the artefact Octopus deploys. Mirrors the contents of `octopus-ttc/{app,k8s}` so the lab has its own self-contained copy.

| File | Purpose |
|------|---------|
| [`Dockerfile`](Dockerfile) | nginx + static `index.html`, with a `VERSION` build-arg that gets baked into the page footer. |
| [`index.html`](index.html) | The actual page — random quotes, rotating in the browser. |
| [`k8s/namespace.yaml`](k8s/namespace.yaml) | Creates the `randomquotes` namespace. |
| [`k8s/deployment.yaml`](k8s/deployment.yaml) | 2-replica Deployment. Image set to `octopussamples/randomquotes-k8s:latest` so the lab works without a private image-pull secret. |
| [`k8s/service.yaml`](k8s/service.yaml) | LoadBalancer Service on port 80. |

## Build locally (optional)

```bash
docker build -t randomquotes:dev .
docker run --rm -p 8080:80 randomquotes:dev
open http://localhost:8080
```

## How Octopus uses these manifests

The deployment step in [`../.octopus/deployment_process.ocl`](../.octopus/) references these YAML files. When the step runs on a K8s deployment target, it applies them into the `randomquotes` namespace.

When you want to switch from the public sample image to your own build, edit `k8s/deployment.yaml` and add an image-pull secret if needed.
