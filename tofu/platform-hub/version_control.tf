resource "octopusdeploy_platform_hub_version_control_username_password_settings" "this" {
  url            = var.ph_repo_url
  default_branch = var.ph_branch
  base_path      = var.ph_base_path
  username       = var.github_username
  password       = var.github_pat
}
