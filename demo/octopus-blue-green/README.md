# Blue/green demo (Octopus path)

Octopus's *native* Kubernetes blue/green via the `Deploy Kubernetes containers` step's `DeploymentStyle = BlueGreen` setting. One step does the whole dance: deploys a new ReplicaSet, waits for it healthy, swaps the Service selector, prunes the old. No hand-rolled YAML, no manual intervention — Octopus is opinionated about what blue/green looks like and this is the opinion.

The runbook lives in [`.octopus/runbooks/blue-green-demo.ocl`](../../.octopus/runbooks/blue-green-demo.ocl) on this branch only — `main` never sees it.

## Prerequisites

- The K8s agent stack applied (`make agent-apply`) so Octopus has a deployment target with role `k8s`.
- Branch-aware Octopus: in the `randomquotes` project's CaC settings, switch the Branch selector to `feat/blue-green` so Octopus loads the runbook.
- Port-forward: `kubectl port-forward svc/ingress-nginx-controller 8080:8080 -n ingress-nginx`.
- At least two GHCR tags to swap between. The `pr-N` tags from open PRs are the easiest source — `pr-1` and `pr-2` are kept alive by PRs #1 and #2.

## The flow

Octopus's blue/green is a *natural consequence* of running the same runbook twice with a different package version. No special "promote" trigger — the second run *is* the promotion.

1. **Octopus → Operations → Runbooks → Blue/Green Demo → Run.**
2. Pick environment (e.g. `Dev`) and the `docker-desktop` deployment target.
3. **Package version dropdown**: pick `pr-1` (this becomes blue).
4. Run. Octopus creates `randomquotes-blue` ReplicaSet, the `randomquotes` Service points at it, the second step adds the Ingress at `octopus-bg-{Source}.localtest.me`. Open it — there's the app on `pr-1`.
5. **Run the runbook again**, this time pick `pr-2` (this becomes green).
6. Octopus creates `randomquotes-green` ReplicaSet, waits for it `Available`, then *atomically* repoints the Service selector. Refresh the URL — now serving `pr-2`. The old (`pr-1`) ReplicaSet sticks around briefly for fast rollback, then is cleaned up.

That's the whole dance. The Service selector swap is what makes it blue/green — there's never a moment where users hit a half-baked rollout.

## Rollback

Run the runbook a third time and pick `pr-1` again. Octopus treats it as the next "color" — same swap dance, just landing back on the old image.

For instant rollback (faster than re-running), `kubectl rollout undo deployment/randomquotes -n randomquotes-bg-demo-{Source}` flips back to the previous ReplicaSet.

## How this differs from the Argo path

| | Argo path | Octopus path |
|---|---|---|
| Strategy lives in… | the chart (`Rollout` CRD) | the deployment step (a checkbox) |
| Rendered as | `Rollout` + active/preview Services + Ingresses | `Deployment` + Service. No preview Service. |
| Smoke-test before swap? | Yes — `previewService` is wired up before promotion | No — Octopus deploys + waits + swaps in one go |
| Promotion trigger | `kubectl argo rollouts promote` (manual) | "next runbook run" (implicit) |
| Where the strategy logic runs | the Rollouts controller, in-cluster | the Octopus task, on the deployment target |

The Argo path is what you reach for when you want a *gated* promotion (smoke-test on preview, then flip). The Octopus path is what you reach for when you want a *clean* promotion (atomic, no half-states, no separate "promote" step) and the version-bump itself is the trigger.

Most importantly: this is *vanilla* Octopus, no chart shenanigans, no sidecar controllers. If you can't install Argo Rollouts in your target cluster (compliance, ops boundary, whatever), the Octopus path still gets you blue/green.

## Tear down

```bash
kubectl delete namespace randomquotes-bg-demo-local
kubectl delete namespace randomquotes-bg-demo-saas
```
