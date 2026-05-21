resource "octopusdeploy_static_worker_pool" "prod_pool" {
  name        = "prod-pool"
  description = "Production-only by convention — prod-approved tooling (e.g. /usr/local/bin/prod-only-check.sh). Routing via the env-scoped Project.WorkerPool variable; non-prod work falls through to Octopus's built-in Default Worker Pool."
  is_default  = false
  sort_order  = 20
}
