# Platform Hub-scoped Git credential. Distinct from `octopusdeploy_git_credential`
# (which control-plane uses for CaC project commits). This one is consumed by
# Platform Hub features that need their own credential — e.g. accounts that
# resolve secrets from Git.
resource "octopusdeploy_platform_hub_git_credential" "github_pat" {
  count       = var.enable_platform_hub ? 1 : 0
  name        = "GitHub PAT (platform-hub)"
  description = "PAT used by Platform Hub features that perform Git operations."
  username    = var.github_username
  password    = var.github_pat

  repository_restrictions = {
    enabled              = true
    allowed_repositories = [var.ph_repo_url]
  }
}
