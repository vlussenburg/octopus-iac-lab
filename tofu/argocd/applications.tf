# Six annotated Argo Applications — one per (tenant, environment). The
# Gateway, watching the cluster, will surface these to Octopus under
# Infrastructure → Argo CD Instances. Octopus matches them to the right
# project / environment / tenant via the argo.octopus.com/* annotations
# the module sets.
#
# This is the "let app/k8s/ finally do something" payoff. The folder's
# manifests (deployment + service + namespace) are pointed at by every
# Application here, with each rendering into its own destination namespace.

locals {
  repo_url = "https://github.com/vlussenburg/octopus-iac-lab"

  argo_app_matrix = {
    for entry in setproduct(
      ["acme-corp", "globex", "initech"],
      ["dev", "production"],
      ) : "${entry[0]}-${entry[1]}" => {
      tenant      = entry[0]
      environment = entry[1]
    }
  }
}

module "randomquotes_argo_app" {
  for_each = local.argo_app_matrix
  source   = "../modules/octopus-argocd-application"

  # Per-Octopus suffix on the Application name itself: both worktrees
  # populate the same shared argocd namespace, so collision-free names
  # matter. local: `randomquotes-acme-corp-dev-local`,
  # saas:  `randomquotes-acme-corp-dev-saas`.
  name                  = "randomquotes-${each.key}-${local.target_kind}"
  destination_namespace = "argo-randomquotes-${local.target_kind}-${each.key}"

  octopus_project_slug     = "randomquotes"
  octopus_environment_slug = each.value.environment
  octopus_tenant_slug      = each.value.tenant

  source_repo_url        = local.repo_url
  source_path            = "app/k8s"
  source_target_revision = "HEAD"

  labels = {
    "lab.octopus.com/source" = local.target_kind
    "lab.octopus.com/tenant" = each.value.tenant
  }

  # Argo Applications live in the argocd namespace itself (the Application
  # CRD object), but DEPLOY into per-tenant×env namespaces above.
  namespace = local.argocd_namespace_name

  providers = {
    kubectl = kubectl
  }

  depends_on = [
    helm_release.argocd,
    helm_release.octopus_argo_gateway,
  ]
}
