# Outputs that the app stack (../app-randomquotes/) consumes via terraform_remote_state.

output "octopus_url" {
  value = var.octopus_url
}

output "space_id" {
  value = var.octopus_space
}

output "environment_ids" {
  value = {
    dev        = octopusdeploy_environment.dev.id
    production = octopusdeploy_environment.production.id
  }
}

output "lifecycle_id" {
  value = octopusdeploy_lifecycle.dev_to_production.id
}

output "project_group_id" {
  value = octopusdeploy_project_group.iac_lab.id
}

output "git_credential_id" {
  value = octopusdeploy_git_credential.github_pat.id
}
