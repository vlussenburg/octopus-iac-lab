# gitops/

Argo CD's source of truth. Folder layout, paths, and `argo.octopus.com/*` annotations are stable contracts — Octopus's Argo CD Gateway watches the cluster for these annotations and surfaces matched Applications under Infrastructure → Argo CD Instances.

Adding a new tenant or environment is a one-file commit:

1. Drop a new YAML under [`applications/randomquotes/{local,saas}/`](applications/randomquotes/) following the existing pattern.
2. `git push`. The App-of-Apps root (managed by `tofu/argocd/`) will pick it up on the next Argo poll cycle (3 min default).
3. No `tofu apply`. No GHA fires (`gitops/**` is outside the `app/**` and `.octopus/**` path filters on `build.yml` / `release.yml`).

## Layout

```
gitops/
├── argocd/                                  # bootstrap + App-of-Apps roots + ingress (synced by argocd-bootstrap)
│   ├── argocd-server-ingress.yaml
│   ├── randomquotes-root-local.yaml
│   └── randomquotes-root-saas.yaml
├── applications/
│   └── randomquotes/
│       ├── local/                           # one Application per (tenant, env), surfaced to Local Octopus
│       │   ├── acme-corp-dev.yaml           #   helm source → gitops/charts/randomquotes + per-tenant values
│       │   ├── acme-corp-production.yaml    #   (mood, icon, color, host, replicas, image.tag — all in
│       │   ├── globex-dev.yaml              #    the leaf's spec.source.helm.valuesObject)
│       │   ├── globex-production.yaml
│       │   ├── initech-dev.yaml
│       │   └── initech-production.yaml
│       └── saas/                            # same six, surfaced to Octopus Cloud
│           └── …
└── charts/
    └── randomquotes/                        # one helm chart, 12 deployments — every leaf Application
        ├── Chart.yaml                       #   instantiates the chart with its own valuesObject overrides
        ├── values.yaml                      #   (tenant, mood, icon, brandColor, watermark, host, image.tag,
        └── templates/                       #   replicaCount). Octopus's update-argo-cd-application-image-
            ├── deployment.yaml              #   tags step bumps `image.tag` in each leaf's valuesObject via
            ├── service.yaml                 #   the argo.octopus.com/image-replace-paths annotation, so dev
            ├── configmap.yaml               #   and prod stay independent.
            └── ingress.yaml
```

## How the Applications get into Argo

`tofu/argocd/` creates exactly **one** Argo Application per worktree, the **App-of-Apps root**:

- `randomquotes-root-local` → syncs `gitops/applications/randomquotes/local/`
- `randomquotes-root-saas`  → syncs `gitops/applications/randomquotes/saas/`

When the root syncs, Argo applies every YAML in the matching folder, materialising the six leaf Applications. Each leaf carries `argo.octopus.com/{project,environment,tenant}` annotations that the Gateway forwards to the right Octopus.

So the 12 Application objects in `argocd` namespace are owned by Argo (created from these YAMLs), not by terraform. Hand-edits to a YAML take effect on the next Argo sync — that's the GitOps loop.

## Annotation contract

Each leaf must carry:

| Annotation | Required | Value |
|---|---|---|
| `argo.octopus.com/project` | yes | Octopus project slug (`randomquotes`) |
| `argo.octopus.com/environment` | yes | Octopus environment slug (`dev` or `production`) |
| `argo.octopus.com/tenant` | yes (for tenanted projects) | Octopus tenant slug |

Reference: <https://octopus.com/docs/argo-cd/annotations>

## Naming convention

- **Application name**: `randomquotes-{tenant}-{env}-{worktree}` — the worktree suffix prevents collision in the shared `argocd` namespace where both worktrees' Applications live.
- **Destination namespace**: `argo-randomquotes-{worktree}-{tenant}-{env}` — the `argo-` prefix keeps these out of the way of the K8s agent's `randomquotes-{worktree}-{tenant}-{env}` namespaces (the push-based path).
- **Source**: every leaf Application points at `gitops/charts/randomquotes` and supplies its own `helm.valuesObject` (tenant, mood, icon, brandColor, watermark, host, replicaCount, image.tag). The chart renders 4 Kubernetes objects per Application: Deployment + Service + ConfigMap + Ingress. The ConfigMap carries the per-tenant `config.json` that `index.html` reads at startup, so each tenant's UI is properly skinned.

## Promoting Dev → Production

Octopus owns the progression. The `Octopus.ArgoCDUpdateImageTags` step runs on whichever env Octopus deploys to and only updates the leaf Application(s) matching that env (via `argo.octopus.com/environment` annotation). So:

1. Push to `app/**` → `build.yml` builds new image → calls `release.yml` → Octopus release created and deployed to **Dev** → Argo step bumps `image.tag` in the 6 dev leaf Applications under `gitops/applications/randomquotes/{local,saas}/*-dev.yaml` → Argo dev Apps sync.
2. To promote: deploy the same Octopus release to **Production** (UI button or another `release.yml` run targeting Prod). Argo step now bumps `image.tag` in the 6 prod leaves → Argo prod Apps sync.

Per-env separation is enforced by Octopus matching annotations on the Applications, not by file paths. Both env's leaves point at the same chart but advance their own `image.tag` independently.

## Reaching the deployed app

Each leaf renders an Ingress with `host: argo-{worktree}-{tenant}-{env}.localtest.me` (e.g. `argo-local-acme-corp-dev.localtest.me`). One port-forward of the cluster's nginx-ingress controller serves all 12:

```bash
kubectl port-forward svc/ingress-nginx-controller 8080:8080 -n ingress-nginx
open http://argo-local-acme-corp-dev.localtest.me:8080
```
