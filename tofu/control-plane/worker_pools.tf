resource "octopusdeploy_static_worker_pool" "prod_pool" {
  name        = "prod-pool"
  description = "Production-only by convention. prod-approved tooling. Routing via env-scoped Project.WorkerPool variable."
  is_default  = false
  sort_order  = 20
}
