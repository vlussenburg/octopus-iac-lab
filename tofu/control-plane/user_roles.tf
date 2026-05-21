resource "octopusdeploy_user_role" "developer_addon" {
  name        = "Developer-AddOn"
  description = "GitCredentialView overlay for the `developers` team — needed for CaC deploys but missing from Octopus's slim built-in roles."

  granted_space_permissions = [
    "GitCredentialView",
  ]
}
