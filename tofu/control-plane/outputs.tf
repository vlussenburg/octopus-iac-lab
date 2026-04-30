# Outputs the app stack (../app-randomquotes/) consumes via terraform_remote_state.
# space_id and octopus_url come from upstream stacks/.env now, not from cp.

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

output "ghcr_feed_id" {
  value       = octopusdeploy_docker_container_registry.ghcr.id
  description = "Octopus feed ID for GHCR. Referenced by the deployment process's image package reference."
}

output "tenant_ids" {
  value = {
    acme_corp = octopusdeploy_tenant.acme_corp.id
    globex    = octopusdeploy_tenant.globex.id
    initech   = octopusdeploy_tenant.initech.id
  }
  description = "Per-tenant IDs consumed by the app stack to wire tenant_project links."
}
