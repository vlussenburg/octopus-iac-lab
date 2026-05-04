# Blue/green demo (Octopus path)

Same blue/green strategy as the Argo demo, but driven by an Octopus *runbook* instead of an Argo Rollout. Demonstrates the contrast: Argo's path is *declarative* (controller reconciles to a manifest); Octopus's path is *imperative + gated* (a process step deploys, a Manual Intervention step waits for a human, a script step flips the Service).

The runbook lives in [`.octopus/runbooks/blue-green-demo.ocl`](../../.octopus/runbooks/blue-green-demo.ocl) on this branch only — it's not on `main`, so production never sees it.

## Prerequisites

- The K8s agent stack applied (`make agent-apply`) so Octopus has a deployment target with role `k8s` to run the kubectl scripts on.
- Branch-aware Octopus: in the `randomquotes` project's CaC settings, switch the Branch selector to `feat/blue-green` so Octopus loads this runbook + the prompted variables.
- A port-forward for the demo hosts: `kubectl port-forward svc/ingress-nginx-controller 8080:8080 -n ingress-nginx`.

## The flow

1. **Octopus → Operations → Runbooks → Blue/Green Demo → Run.**
2. Pick environment `Dev` (or `Production`). Pick the `docker-desktop` deployment target (role `k8s`).
3. Enter prompted variables:
   - `Blue image tag` = `pr-1`
   - `Green image tag` = `pr-2`
4. **Step 1 — Deploy blue.** Creates namespace `randomquotes-bg-demo-{Source}`, deploys `randomquotes-blue` Deployment + `randomquotes-active` Service (selector pinned to `version=blue`) + Ingress on `octopus-bg-{Source}.localtest.me`.
5. **Step 2 — Deploy green.** Deploys `randomquotes-green` Deployment + `randomquotes-preview` Service (selector pinned to `version=green`) + Ingress on `octopus-bg-{Source}-preview.localtest.me`.
6. **Step 3 — Smoke-test green.** Manual Intervention. Open `http://octopus-bg-{Source}-preview.localtest.me:8080`, validate the new image, then **Approve** to continue (or **Fail** to halt).
7. **Step 4 — Promote.** Patches `randomquotes-active`'s selector from `version=blue` to `version=green`. Refresh `http://octopus-bg-{Source}.localtest.me:8080` — now serving green.

Old (blue) Deployment stays running; rollback = re-run with versions swapped, or `kubectl delete deployment randomquotes-blue -n randomquotes-bg-demo-{Source}`.

## What's different from the Argo demo

| | Argo path | Octopus path |
|---|---|---|
| Deploy model | declarative `Rollout` CRD | imperative `kubectl apply` from a process step |
| Promotion gate | `kubectl argo rollouts promote` (CLI / annotation) | Manual Intervention step in Octopus, audit-logged |
| Service selector swap | controller-managed | explicit `kubectl patch` script |
| Rollback window | `scaleDownDelaySeconds: 30` then auto-prune | manual — old Deployment stays until you delete it |
| Audit trail | argo CLI / git commits | Octopus task log + manual-intervention attribution |

The Argo path is what you'd reach for when "ship safely + cheaply" is the brief. The Octopus path is what you'd reach for when there's a compliance / change-management story attached to promotions — the Manual Intervention has a responsible team, instructions, and an unforgeable audit record of who clicked Approve.

## Tear down

```bash
kubectl delete namespace randomquotes-bg-demo-local
kubectl delete namespace randomquotes-bg-demo-saas
```
