# Single Argo Application per worktree — the App-of-Apps root. Argo syncs
# this, sees a folder of more Application manifests at the source path,
# applies them, and the six leaf Applications materialise. Each leaf then
# syncs `app/k8s/` into its own destination namespace.
#
# Per-tenant Application YAMLs are committed under
# `gitops/applications/randomquotes/{local,saas}/`. Adding a tenant is a
# one-file commit there — no `tofu apply` needed; Argo discovers it on the
# next poll cycle (3 min default).
#
# Path-filter safety: gitops/** is outside both `app/**` (build.yml) and
# `.octopus/**` (release.yml), so commits to those YAMLs don't fire CI.

resource "kubectl_manifest" "randomquotes_root" {
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "randomquotes-root-${local.target_kind}"
      namespace = local.argocd_namespace_name
      labels = {
        "lab.octopus.com/source" = local.target_kind
        "lab.octopus.com/role"   = "app-of-apps-root"
      }
    }
    spec = {
      project = "default"
      source = {
        repoURL        = "https://github.com/vlussenburg/octopus-iac-lab"
        path           = "gitops/applications/randomquotes/${local.target_kind}"
        targetRevision = "HEAD"
        directory = {
          recurse = false
        }
      }
      destination = {
        # The leaves are Application CRDs themselves — they live in the
        # argocd namespace, not in any tenant's destination.
        server    = "https://kubernetes.default.svc"
        namespace = local.argocd_namespace_name
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          # Don't try to set ownerReferences on the leaves — Argo manages
          # them as independent Applications, the root just bootstraps.
          "ApplyOutOfSyncOnly=true",
        ]
      }
    }
  })

  server_side_apply = true
  force_conflicts   = true

  depends_on = [
    helm_release.argocd,
    module.gateway,
  ]
}
