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
  tenanted_deployment_participation = "Untenanted"
  is_version_controlled             = true

  git_library_persistence_settings {
    url               = var.cac_repo_url
    default_branch    = var.cac_branch
    base_path         = var.cac_base_path
    git_credential_id = local.cp.git_credential_id
  }
}
