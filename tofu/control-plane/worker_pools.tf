# Two static worker pools that anchor the locked-down-prod-pool demo.
#
# `dev-pool` is Octopus's `IsDefault` pool — any step that doesn't pick
# a pool explicitly lands here. `prod-pool` is everything else: any step
# that resolves `Octopus.Action.WorkerPool` (directly or via a variable)
# to its slug. Steps don't need a special permission to pick prod-pool;
# Octopus's per-pool RBAC doesn't exist (see "Octopus limitation"
# below). The env-scoped `Project.WorkerPool` project variable (in
# .octopus-locked-down-prod-pool/variables.ocl) is what routes
# Production deploys to prod-pool by default.
#
# Octopus limitation worth knowing: `WorkerView` and `WorkerEdit` both
# have `RestrictedTo: []` in `/api/permissions/all` — they're space-wide
# on/off, with no per-pool scoping. Workers themselves have no
# environment scope, no roles, no label-based selection — only pool
# membership, machine policy, and optional tenant participation. So a
# user with `ProcessEdit` (which any project author needs) can hand-pin
# `Octopus.Action.WorkerPool = "prod-pool"` on any step and Octopus
# accepts it. The only structural gate against that is a process-
# validation policy at submit time — the companion `worker_pool_gate.rego`
# on demo/platform-hub-opa is the placeholder for that, awaiting Octopus
# exposing the Platform Hub process-policy resource type.

resource "octopusdeploy_static_worker_pool" "dev_pool" {
  name        = "dev-pool"
  description = "Default pool (Octopus IsDefault). Any step that doesn't pick a pool resolves here. dev-approved tooling, dev creds."
  is_default  = true
  sort_order  = 10
}

resource "octopusdeploy_static_worker_pool" "prod_pool" {
  name        = "prod-pool"
  description = "Production-only by convention — prod-approved tooling (e.g. /usr/local/bin/prod-only-check.sh), prod creds, locked-down image. Pool membership is not RBAC-gated (Octopus has no per-pool ACL); routing to this pool is via the env-scoped Project.WorkerPool variable + the OPA process-validation policy on demo/platform-hub-opa."
  is_default  = false
  sort_order  = 20
}
