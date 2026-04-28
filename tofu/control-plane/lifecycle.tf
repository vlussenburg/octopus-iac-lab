resource "octopusdeploy_lifecycle" "dev_to_production" {
  name        = "Dev to Production"
  description = "Deploy to Dev, then promote to Production."

  phase {
    name                                  = "Dev"
    optional_deployment_targets           = [octopusdeploy_environment.dev.id]
    minimum_environments_before_promotion = 1
    is_optional_phase                     = false
  }

  phase {
    name                                  = "Production"
    optional_deployment_targets           = [octopusdeploy_environment.production.id]
    minimum_environments_before_promotion = 1
    is_optional_phase                     = false
  }

  release_retention_policy {
    unit                = "Days"
    quantity_to_keep    = 30
    should_keep_forever = false
  }

  tentacle_retention_policy {
    unit                = "Days"
    quantity_to_keep    = 30
    should_keep_forever = false
  }
}
