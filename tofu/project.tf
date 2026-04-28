# The CaC project — the whole reason this lab exists.
# is_version_controlled = true flips the project into Config-as-Code mode:
# its deployment process, channels, variables (non-sensitive), and runbooks
# serialise to OCL files at base_path in the repo.
#
# Three persistence-settings blocks are available in the provider:
#   - git_anonymous_persistence_settings         (public repo, no auth)
#   - git_library_persistence_settings           (references an octopusdeploy_git_credential — what we use)
#   - git_username_password_persistence_settings (inline creds — fine for one-offs, worse for rotation)
resource "octopusdeploy_project" "lab" {
  name                              = "iac-lab"
  description                       = "Sandbox project — version-controlled in Git via CaC."
  project_group_id                  = octopusdeploy_project_group.iac_lab.id
  lifecycle_id                      = octopusdeploy_lifecycle.dev_to_production.id
  default_guided_failure_mode       = "EnvironmentDefault"
  tenanted_deployment_participation = "Untenanted"
  is_version_controlled             = true

  git_library_persistence_settings {
    url               = var.cac_repo_url
    default_branch    = var.cac_branch
    base_path         = var.cac_base_path
    git_credential_id = octopusdeploy_git_credential.github_pat.id
  }
}
