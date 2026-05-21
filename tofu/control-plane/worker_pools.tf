# prod-pool exists on both targets so the OCL slug resolves on both:
#   - local: STATIC pool, populated by the polling tentacle in compose/.
#   - SaaS: DYNAMIC pool, auto-provisioned by Octopus Cloud per task.

resource "octopusdeploy_static_worker_pool" "prod_pool" {
  count = local.source_kind == "saas" ? 0 : 1

  name        = "prod-pool"
  description = "Production-only by convention. Static pool — the polling tentacle in compose/ registers here."
  is_default  = false
  sort_order  = 20
}

resource "octopusdeploy_dynamic_worker_pool" "prod_pool" {
  count = local.source_kind == "saas" ? 1 : 0

  name        = "prod-pool"
  description = "Production-only by convention. Dynamic pool — Octopus Cloud auto-provisions an Ubuntu worker per task."
  is_default  = false
  sort_order  = 20
  worker_type = "UbuntuDefault"
}
