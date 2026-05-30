# Demo-lab regression

Repeatable verification that PR-preview images (`1.1.X-prN`) never reach the
demo Dev or Production environments, and that demo deploys actually succeed —
across both Octopus instances (LOCAL + SaaS).

Two pieces:

| Script | Mutates? | Use |
|---|---|---|
| `check.py` | no (read-only) | Assert the invariants. Safe to run anytime / in CI. |
| `e2e.py` | yes | Drive a real build + deploy, then run the checker. Run by hand. |

Credentials come from the **local worktree's `.env`** (it holds both instances'
keys), or from the process environment. Space IDs are resolved by name
(`IaC Sandbox`) — nothing instance-specific is hardcoded.

## check.py

```bash
python3 scripts/regression/check.py            # uses ./.env
python3 scripts/regression/check.py --env /path/to/.env
```

Invariants 1–3, per demo project, on both instances:

1. **No leak** — no Dev runs a `-pr` version.
2. **Prod OK** — no Production deployment is in a `Failed` state.
3. **Rules** — every image-bearing action is covered by a `Stable`-channel rule
   pinned to stable (`tag ^$`), so the feed trigger can't backfill it with a
   `-pr` image. This catches latent leaks (e.g. an `Update Argo CD` action that
   the deploy action's pin doesn't cover) before they ship.

Invariants 4–5 are cluster-wide (both instances share one cluster):

4. **Argo** — no non-preview demo Argo Application is actually serving a `-pr`
   image. Invariants 1–3 read Octopus; this reads what Argo deployed from the
   gitops repo, catching a stale `-pr` tag left in a per-branch `values-*.yaml`
   that Octopus's dashboard no longer shows but Argo keeps reconciling.
5. **Decomm** — no preview namespace survives for a PR that is closed on GitHub
   (decommission leftover). Open-PR previews are left alone.

Invariants 4 & 5 need a reachable cluster (`kubectl`) and, for 5, `gh`. When
those are unavailable they **SKIP** (not fail), so the checker still runs in CI
without a cluster.

Exits non-zero (and prints a punch list) on any violation.

## e2e.py

```bash
python3 scripts/regression/e2e.py build-stable        # push main, wait for Dev convergence -> prints 1.1.<run>
python3 scripts/regression/e2e.py deploy-prod 1.1.179 # deploy a stable version to Production/acme-corp everywhere
python3 scripts/regression/e2e.py decommission        # open a preview PR, then close it and assert Argo prunes app + namespace
python3 scripts/regression/e2e.py check               # == check.py
python3 scripts/regression/e2e.py all                 # build-stable -> deploy-prod -> check
```

`build-stable` bumps the `<title>` in `app/index.html`, commits, pushes to
`main`, watches the `build.yml` run, then waits until every demo Dev shows the
new stable version. `deploy-prod` is the Production coverage the Dev-only
trigger loop doesn't exercise: it deploys the given stable version to the
`Production` environment for tenant `acme-corp` on every demo project and fails
if any deploy doesn't reach `Success`.

Preview-leak verification is left to `check.py` invariant 1: trigger a PR build
out of band (push to a `feat/*` branch), then run the checker — Dev must remain
on stable.

`decommission` is the active counterpart to check.py invariant 5. It opens a
throwaway `feat/regression-decomm-*` PR and waits until **both** preview systems
materialise it:

- Argo's PullRequest generator → `randomquotes-preview-pr-<N>` Application +
  `argo-randomquotes-preview-pr-<N>` namespace;
- Octopus's ephemeral channel (the `feat/*` PR build pushes the `pr<N>` image,
  `create-ephemeral-release` lands it on the channel, spin-up-preview runs) →
  a `preview-pr<N>` env per instance + a `randomquotes-<source>-preview-pr<N>`
  namespace.

It then closes the PR and asserts both fully tear down. **Argo** prunes on close
natively — the namespace half is the regression that matters:
`CreateNamespace=true` used to leave the namespace as an untracked orphan after
prune; rendering it as a tracked chart resource puts it in the finalizer
cascade. **Octopus** has no native on-close teardown (verified against the
server binary: deprovision fires only off the parent env's inactivity timer,
there is no PR-close handler, and `GitReferenceRules` gate provisioning only).
The official on-close path is a GitHub Action, which this lab avoids — so the
test drives Octopus's teardown the one non-GHA way the API allows: it POSTs the
deprovision command per instance (which runs the teardown-preview runbook) and
asserts the Octopus namespace is pruned too. Needs a reachable cluster + both
instances' creds; cleans up the branch/PR/worktree and any leftover Octopus env
in a `finally`. The 24 h parent-env timer remains the backstop for previews
whose close event is missed entirely.
