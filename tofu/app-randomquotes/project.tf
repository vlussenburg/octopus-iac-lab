# The randomquotes app project — version-controlled in Git via CaC.
#
# Lifecycle, project group, and Git credential come from the control-plane
# stack via terraform_remote_state. Deployment process, channels, runbooks,
# and non-sensitive variables are NOT defined here — they live in
# .octopus/*.ocl in this repo and are owned by Octopus.
locals {
  cp = data.terraform_remote_state.control_plane.outputs

  # Which environments each tenant deploys to. acme-corp is the canary tenant
  # (full Dev → Production); the rest are Production-only. Single source for both
  # the project-tenant links below and the Brand.DisplayName scope.
  tenant_environment_keys = {
    acme_corp = ["dev", "production"]
    globex    = ["production"]
    initech   = ["production"]
  }
}

resource "octopusdeploy_project" "randomquotes" {
  name                              = "randomquotes"
  description                       = "Random Quotes K8s sample app — deployment process lives in .octopus/."
  project_group_id                  = local.cp.project_group_id
  lifecycle_id                      = local.cp.lifecycle_id
  default_guided_failure_mode       = "EnvironmentDefault"
  tenanted_deployment_participation = "Tenanted"
  is_version_controlled             = true

  # Register the existing CaC preview runbooks as the project's native
  # ephemeral-env provisioning/deprovisioning hooks. CaC runbook ids are their
  # slugs (no octopusdeploy_runbook data source in 1.12 — same gap the
  # scheduled triggers hit). Pairs with the parent env + ephemeral channel in
  # ephemeral.tf to populate the project's Ephemeral Environments page.
  provisioning_runbook_id   = "spin-up-preview"
  deprovisioning_runbook_id = "teardown-preview"

  # Per-Octopus values that can't live in shared OCL — Source (local|saas)
  # is set there. Resolves naturally as #{Source} in deployment + runbook OCL.
  included_library_variable_sets = [local.cp.lab_source_set_id]

  # The one genuinely per-tenant value that isn't an archetype: each customer's
  # display name. Unlike tier/mood (tag-scoped in variables.ocl), a brand name
  # can't be derived from a tag, so it's a project template the tenant fills in.
  # Values live in tenant_variables.tf so they stay reproducible from git.
  template {
    name      = "Brand.DisplayName"
    label     = "Display name"
    help_text = "Customer-facing brand name shown in the app header."
    display_settings = {
      "Octopus.ControlType" = "SingleLineText"
    }
  }

  git_library_persistence_settings {
    url               = var.cac_repo_url
    default_branch    = var.cac_branch
    base_path         = var.cac_base_path
    git_credential_id = local.cp.git_credential_id
  }
}

# Connect each tenant to the project. Tenants opt into specific environments
# per project — that's how Octopus models "this customer's lifecycle is shorter
# than that one's". Environments come from local.tenant_environment_keys.
resource "octopusdeploy_tenant_project" "tenants" {
  for_each = local.cp.tenant_ids

  tenant_id       = each.value
  project_id      = octopusdeploy_project.randomquotes.id
  environment_ids = [for e in local.tenant_environment_keys[each.key] : local.cp.environment_ids[e]]
}
