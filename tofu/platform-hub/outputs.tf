output "platform_hub_git_credential_id" {
  value = try(octopusdeploy_platform_hub_git_credential.github_pat[0].id, null)
}

output "platform_hub_repo_url" {
  value = try(octopusdeploy_platform_hub_version_control_username_password_settings.this[0].url, null)
}
