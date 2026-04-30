# GitHub Container Registry feed. Octopus uses this to resolve image
# references at deploy time — for example, `ghcr.io/<owner>/<repo>` in the
# templated K8s manifest. Authenticated with the same PAT we use for CaC,
# scoped to `repo` + `read:packages`.
resource "octopusdeploy_docker_container_registry" "ghcr" {
  name = "GHCR"
  # Pin the slug — referenced by the deployment process OCL
  # (.octopus/deployment_process.ocl), would otherwise drift if the name
  # ever changed.
  slug        = "ghcr"
  feed_uri    = "https://ghcr.io"
  username    = var.github_username
  password    = var.github_pat
  api_version = "v2"
}
