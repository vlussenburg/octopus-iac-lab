output "project_url" {
  value       = "${var.octopus_url}/app#/${octopusdeploy_project.lab.space_id}/projects/${octopusdeploy_project.lab.id}/deployments/process"
  description = "Open the CaC project in the Octopus UI."
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

output "git_credential_id" {
  value = octopusdeploy_git_credential.github_pat.id
}
