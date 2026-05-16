resource "octopusdeploy_environment" "dev" {
  name                         = "Dev"
  description                  = "Development environment"
  use_guided_failure           = false
  allow_dynamic_infrastructure = true
}

resource "octopusdeploy_environment" "production" {
  name                         = "Production"
  description                  = "Production environment"
  use_guided_failure           = true
  allow_dynamic_infrastructure = true

  # ServiceNow change-control gate. The env-level toggle marks Production
  # as change-controlled lab-wide; it has no runtime effect until an actual
  # SNow connection is wired in via tofu/servicenow/ (applied only when
  # the snow demo is active). Project-level enrollment (connection_id,
  # change template, etc.) lives on the consuming projects.
  dynamic "servicenow_extension_settings" {
    for_each = var.enable_servicenow_change_control ? [1] : []
    content {
      is_enabled = true
    }
  }
}
