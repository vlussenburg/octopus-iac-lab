resource "octopusdeploy_user_role" "developer_addon" {
  name        = "Developer-AddOn"
  description = "Read-only overlay for the `developers` team — adds GitCredentialView (needed for CaC deploys) and VariableView (project variables page), neither of which Octopus's slim built-in roles include."

  granted_space_permissions = [
    "GitCredentialView",
    "VariableView",
  ]
}
