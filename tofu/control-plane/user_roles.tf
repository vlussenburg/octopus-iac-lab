resource "octopusdeploy_user_role" "developer_addon" {
  name        = "Developer-AddOn"
  description = "GitCredentialView + VariableView overlay for the developers team — read-only gaps not covered by Octopus's slim built-in roles."

  granted_space_permissions = [
    "GitCredentialView",
    "VariableView",
  ]
}
