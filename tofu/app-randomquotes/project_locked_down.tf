resource "octopusdeploy_project" "locked_down_prod_pool" {
  name                              = "randomquotes-locked-down-prod-pool"
  description                       = "Random Quotes with the locked-down-prod-pool RBAC story — devs deploy to Dev only, Production lands on prod-pool worker."
  project_group_id                  = local.cp.project_group_id
  lifecycle_id                      = local.cp.lifecycle_id
  default_guided_failure_mode       = "EnvironmentDefault"
  tenanted_deployment_participation = "Tenanted"
  is_version_controlled             = true

  included_library_variable_sets = [local.cp.lab_source_set_id]

  git_library_persistence_settings {
    url               = var.cac_repo_url
    default_branch    = "main"
    base_path         = ".octopus-locked-down-prod-pool"
    git_credential_id = local.cp.git_credential_id
  }
}

resource "octopusdeploy_variable" "locked_down_source" {
  owner_id        = octopusdeploy_project.locked_down_prod_pool.id
  name            = "Source"
  type            = "Sensitive"
  sensitive_value = "${strcontains(var.octopus_url, "octopus.app") ? "saas" : "local"}-locked-down"
  is_sensitive    = true
}

resource "octopusdeploy_tenant_project" "locked_down_tenants" {
  for_each = local.cp.tenant_ids

  tenant_id  = each.value
  project_id = octopusdeploy_project.locked_down_prod_pool.id
  environment_ids = each.key == "acme_corp" ? [
    local.cp.environment_ids.dev,
    local.cp.environment_ids.production,
  ] : [
    local.cp.environment_ids.production,
  ]
}
