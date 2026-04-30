# gitops/

Argo CD's source of truth. Folder layout, paths, and `argo.octopus.com/*` annotations are stable contracts — Octopus's Argo CD Gateway watches the cluster for these annotations and surfaces matched Applications under Infrastructure → Argo CD Instances.

Adding a new tenant or environment is a one-file commit:

1. Drop a new YAML under [`applications/randomquotes/{local,saas}/`](applications/randomquotes/) following the existing pattern.
2. `git push`. The App-of-Apps root (managed by `tofu/argocd/`) will pick it up on the next Argo poll cycle (3 min default).
3. No `tofu apply`. No GHA fires (`gitops/**` is outside the `app/**` and `.octopus/**` path filters on `build.yml` / `release.yml`).

## Layout

```
gitops/
└── applications/
    └── randomquotes/
        ├── local/                              # one Application per (tenant, env), surfaced to Local Octopus
        │   ├── acme-corp-dev.yaml
        │   ├── acme-corp-production.yaml
        │   ├── globex-dev.yaml
        │   ├── globex-production.yaml
        │   ├── initech-dev.yaml
        │   └── initech-production.yaml
        └── saas/                               # same six, surfaced to Octopus Cloud
            └── …
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
