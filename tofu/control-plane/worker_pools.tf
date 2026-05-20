# Two static worker pools that anchor the locked-down-prod-pool demo.
#
# `dev-pool` is the default — Octopus auto-assigns it to any step that
# doesn't pick a pool explicitly. `prod-pool` only gets work when the
# project's `Project.WorkerPool` variable resolves to it (env-scoped to
# Production), and only Prod-Deployer / admin teams have WorkerView on it.
#
# Octopus limitation worth knowing: `WorkerView` is a space-wide permission
# (`RestrictedTo: []`) — you cannot scope WorkerView to a specific pool.
# The "developer cannot see prod-pool" outcome is therefore expressed as
# "developer has no WorkerView at all", so the entire pool list is empty
# for them. Prod-Deployer + admins see both pools. The env-scoped variable
# is what actually routes Production deployments to prod-pool.

resource "octopusdeploy_static_worker_pool" "dev_pool" {
  name        = "dev-pool"
  description = "Open to all teams. dev-approved tooling. The default pool — non-prod work lands here automatically."
  is_default  = true
  sort_order  = 10
}

resource "octopusdeploy_static_worker_pool" "prod_pool" {
  name        = "prod-pool"
  description = "Production-only. prod-approved tooling, prod creds, locked-down image. Visibility gated to Prod-Deployer + Administrators; Developer-Restricted has no WorkerView and cannot see this pool in any list or dropdown."
  is_default  = false
  sort_order  = 20
}
