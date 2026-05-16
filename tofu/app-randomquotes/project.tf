# The randomquotes app project — version-controlled in Git via CaC.
#
# Lifecycle, project group, and Git credential come from the control-plane
# stack via terraform_remote_state. Deployment process, channels, runbooks,
# and non-sensitive variables are NOT defined here — they live in
# .octopus/*.ocl in this repo and are owned by Octopus.
locals {
  cp = data.terraform_remote_state.control_plane.outputs
}

resource "octopusdeploy_project" "randomquotes" {
  name                              = "randomquotes"
  description                       = "Random Quotes K8s sample app — deployment process lives in .octopus/."
  project_group_id                  = local.cp.project_group_id
  lifecycle_id                      = local.cp.lifecycle_id
  default_guided_failure_mode       = "EnvironmentDefault"
  tenanted_deployment_participation = "Tenanted"
  is_version_controlled             = true

  # Per-Octopus values that can't live in shared OCL — Source (local|saas)
  # is set there. Resolves naturally as #{Source} in deployment + runbook OCL.
  included_library_variable_sets = [local.cp.lab_source_set_id]

  git_library_persistence_settings {
    url               = var.cac_repo_url
    default_branch    = var.cac_branch
    base_path         = var.cac_base_path
    git_credential_id = local.cp.git_credential_id
  }
}

# Connect each tenant to the project. Tenants opt into specific
# environments per project — that's how Octopus models "this customer's
# lifecycle is shorter than that one's". acme-corp gets the full
# Dev → Production lifecycle (acts as the canary tenant for new
# releases); globex + initech are Production-only (changes pass through
# Dev via acme-corp's run, then promote forward to the rest).
resource "octopusdeploy_tenant_project" "tenants" {
  for_each = local.cp.tenant_ids

  tenant_id  = each.value
  project_id = octopusdeploy_project.randomquotes.id
  environment_ids = each.key == "acme_corp" ? [
    local.cp.environment_ids.dev,
    local.cp.environment_ids.production,
  ] : [
    local.cp.environment_ids.production,
  ]
}
