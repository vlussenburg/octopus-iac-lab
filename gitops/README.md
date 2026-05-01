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
│       │   ├── acme-corp-dev.yaml           #   spec.source.path → gitops/k8s/dev
│       │   ├── acme-corp-production.yaml    #   spec.source.path → gitops/k8s/production
│       │   ├── globex-dev.yaml
│       │   ├── globex-production.yaml
│       │   ├── initech-dev.yaml
│       │   └── initech-production.yaml
│       └── saas/                            # same six, surfaced to Octopus Cloud
│           └── …
└── k8s/                                     # the actual workload manifests (Deployment + Service)
    ├── dev/                                 # Octopus's update-argo-cd-application-image-tags step writes
    │   ├── deployment.yaml                  #   here on Dev deploys (matches Apps with .../environment: dev).
    │   └── service.yaml
    └── production/                          # Same step writes here on Production deploys (matches Apps with
        ├── deployment.yaml                  #   .../environment: production). Per-env separation is enforced
        └── service.yaml                     #   by spec.source.path on each leaf Application.
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
- **Source path**: `gitops/k8s/{env}` — dev and production each have their own folder, so a Dev release can't accidentally update prod's manifests and vice versa.

## Promoting Dev → Production

Octopus owns the progression. The `Octopus.ArgoCDUpdateImageTags` step runs on every env it's deployed to and only writes into the matching `gitops/k8s/{env}/` folder (because the Argo Applications for that env have `spec.source.path` pinned to that folder). So the flow is:

1. Push to `app/**` → `build.yml` builds new image → calls `release.yml` → Octopus release created and deployed to **Dev** → Argo step writes to `gitops/k8s/dev/deployment.yaml` → Argo dev Apps sync.
2. To promote: deploy the same Octopus release to **Production** (UI button or another `release.yml` run targeting Prod). Argo step now writes to `gitops/k8s/production/deployment.yaml` → Argo prod Apps sync.

The two folders never get touched by the same Octopus deploy — env separation is enforced by the Argo Application `spec.source.path` pin, not by manual file copies.
