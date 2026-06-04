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

  # Per-tenant randomquotes properties. A tenant has no display name, mood,
  # icon, or colour until it's deployed to *this* app — they're facets of how a
  # customer appears in randomquotes, not customer identity — so they're project
  # templates the tenant fills in, not control-plane tenant tags. (tier stays a
  # tenant tag: it's a plan attribute that exists with or without an app.)
  # Values live in tenant_variables.tf so a nuked instance restores them on
  # apply. Previews deploy untenanted, so their values stay channel-scoped in
  # .octopus/variables.ocl — the template and the OCL value share a name and
  # resolve by scope.
  template {
    name      = "Brand.DisplayName"
    label     = "Display name"
    help_text = "Customer-facing brand name shown in the app header."
    display_settings = {
      "Octopus.ControlType" = "SingleLineText"
    }
  }

  # Constrained enum: the app only ships quotes for these three themes, so the
  # template enforces them (a Select), the way the old `mood` tag set did before
  # mood became a per-tenant project value.
  template {
    name      = "Featured.Mood"
    label     = "Mood"
    help_text = "Quote curation theme the app filters on."
    display_settings = {
      "Octopus.ControlType"   = "Select"
      "Octopus.SelectOptions" = "comedy|Comedy\nsilicon-valley|Silicon Valley\nstoic|Stoic"
    }
  }

  template {
    name      = "Brand.Icon"
    label     = "Brand icon"
    help_text = "Emoji shown in the app header for this customer."
    display_settings = {
      "Octopus.ControlType" = "SingleLineText"
    }
  }

  template {
    name      = "Brand.Color"
    label     = "Brand colour"
    help_text = "Accent colour (hex) for this customer's branding."
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
