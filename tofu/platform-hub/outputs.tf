output "platform_hub_git_credential_id" {
  value = octopusdeploy_platform_hub_git_credential.github_pat.id
}

output "platform_hub_repo_url" {
  value = octopusdeploy_platform_hub_version_control_username_password_settings.this.url
}
