# PAT-based credential Octopus uses to read/write OCL in the CaC repo.
# Username can be anything when authenticating GitHub with a PAT — the PAT carries the identity.
resource "octopusdeploy_git_credential" "github_pat" {
  name        = "GitHub PAT (octopus-iac-lab)"
  description = "Personal access token used by Octopus for Config-as-Code."
  type        = "UsernamePassword"
  username    = var.github_username
  password    = var.github_pat
}
