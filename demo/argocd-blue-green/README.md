# Blue/green demo (Argo path)

Self-contained walkthrough of an [Argo Rollouts](https://argoproj.github.io/argo-rollouts/) blue/green deployment of `randomquotes`. Lives outside the App-of-Apps roots so it doesn't sync from main automatically — the entire demo is `make bg-demo-*` targets that opt-in by `kubectl apply`-ing a single Application.

The chart's `blueGreen.enabled` flag (default `false`) is what makes this work — the production tenant leaves under `gitops/applications/randomquotes/{local,saas}/` keep blueGreen off; this demo flips it on for an isolated namespace.

## Prerequisites

- `make agent-apply` already ran (installs the Argo Rollouts controller cluster-wide)
- `kubectl-argo-rollouts` plugin: `brew install argoproj/tap/kubectl-argo-rollouts`
- A port-forward for `*.localtest.me`: `kubectl port-forward svc/ingress-nginx-controller 8080:8080 -n ingress-nginx`
- Two distinct images already pushed to GHCR. The lab's `build.yml` produces `pr-N` tags on PR pushes — open PRs leave their tags hanging in GHCR, so two recent PRs is the easiest source. Substitute any other tags you have.

## The flow

```bash
# 1. Stand up the demo on the "blue" image (whatever tag you've got).
make bg-demo-up TAG=pr-1

# Open http://argo-bg.localtest.me:8080 — that's BLUE serving live traffic.
# http://argo-bg-preview.localtest.me:8080 — that's the PREVIEW host. Right
# now active and preview point at the same ReplicaSet (steady state).

# 2. Bump the image to "green". The Rollouts controller spins up a second
#    ReplicaSet, points the preview Service at it, leaves active alone.
make bg-demo-up TAG=pr-2

# Refresh:
#   argo-bg.localtest.me           → still BLUE  (pr-1)
#   argo-bg-preview.localtest.me   → now GREEN   (pr-2)
# This is the smoke-test window. Real load still hits blue.

# 3. Watch the Rollout state.
make bg-demo-status
# Status: Paused (BlueGreenPause) — the controller is waiting for promotion.

# 4. Promote. The active Service selector flips to the new ReplicaSet.
make bg-demo-promote

# Refresh argo-bg.localtest.me — now GREEN. Old ReplicaSet sticks around
# for `scaleDownDelaySeconds` (30s) for instant rollback, then scales to 0.

# 5. Tear down.
make bg-demo-down
```

## Rollback

If green is bad, just don't promote — the active Service is still pointing at blue. Either:

- `make bg-demo-up TAG=pr-1` — re-applies blue's tag, controller rolls forward to it (counter-intuitive but the *current* active stays serving while a new ReplicaSet matching pr-1 spawns and replaces what the controller thinks is "the new revision")
- Easier: `kubectl argo rollouts abort randomquotes -n argo-randomquotes-bg-demo` — drops the green ReplicaSet, leaves blue serving

## What's actually rendered

`helm template gitops/charts/randomquotes --set blueGreen.enabled=true …` produces:

| Resource | Purpose |
|---|---|
| `Rollout/randomquotes` | replaces the chart's `Deployment` when blueGreen is on |
| `Service/randomquotes-active` | selector flips on `argo rollouts promote` |
| `Service/randomquotes-preview` | always points at the newest ReplicaSet |
| `Ingress/randomquotes-active` | host = `Values.host` |
| `Ingress/randomquotes-preview` | host = `Values.blueGreen.previewHost` |

The Rollouts controller (installed via [`tofu/k8s-agent/argo_rollouts.tf`](../../tofu/k8s-agent/argo_rollouts.tf)) does the selector-flipping; the chart just declares the resources.
