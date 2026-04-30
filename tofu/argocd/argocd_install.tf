# ArgoCD itself — shared cluster infra. Owned by exactly ONE worktree at a
# time (default: the local self-host worktree; SaaS piggybacks). The other
# worktree sets `install_argocd = false` and references the same namespace
# via the `argocd_namespace_name` local.
#
# Two lab-specific tweaks to the upstream chart:
#   1. `octopus` account configured with apiKey-only capability — that's
#      what each Gateway authenticates as.
#   2. RBAC policy granting `octopus` the minimum permissions the Gateways
#      need (per https://octopus.com/docs/argo-cd/instances/terraform-bootstrap).

resource "kubernetes_namespace_v1" "argocd" {
  count = local.install_argocd_final ? 1 : 0

  metadata {
    name = var.argocd_namespace
  }
}

resource "helm_release" "argocd" {
  count = local.install_argocd_final ? 1 : 0

  name             = "argocd"
  namespace        = kubernetes_namespace_v1.argocd[0].metadata[0].name
  create_namespace = false

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version

  atomic = true
  wait   = true

  # `values` (yamlencode) instead of `set` blocks: helm's --set parser
  # treats commas as field separators, which mangles RBAC policy CSVs.
  # yamlencode hands the chart a clean YAML doc and avoids the escaping mess.
  values = [
    yamlencode({
      configs = {
        cm = {
          # `octopus` is the account each Gateway authenticates as. apiKey
          # capability is sufficient — the Gateway only consumes JWTs, it
          # doesn't ever log in interactively.
          "accounts.octopus" = "apiKey"
        }
        rbac = {
          # Minimum permissions the Octopus Gateway needs (per
          # https://octopus.com/docs/argo-cd/instances/terraform-bootstrap).
          # `g, octopus, role:octopus` binds the user to the role.
          "policy.csv" = trimspace(<<-EOT
            p, role:octopus, applications, get, */*, allow
            p, role:octopus, applications, sync, */*, allow
            p, role:octopus, applications, action/*, */*, allow
            p, role:octopus, applications, override, */*, allow
            p, role:octopus, applications, update, */*, allow
            p, role:octopus, applications, create, */*, allow
            p, role:octopus, applications, delete, */*, allow
            p, role:octopus, clusters, get, *, allow
            p, role:octopus, repositories, get, *, allow
            p, role:octopus, projects, get, *, allow
            p, role:octopus, logs, get, */*, allow
            g, octopus, role:octopus
          EOT
          )
        }
        params = {
          # argocd-server runs HTTP-only — nginx-ingress terminates TLS
          # in front. Lab-friendly; for anything serious, terminate at
          # argocd-server with a real cert.
          "server.insecure" = true
        }
      }

      # Seed a single bootstrap Application as part of the helm install.
      # It syncs `gitops/argocd/`, which contains the per-Octopus root
      # Applications (App-of-Apps pattern) AND the argocd-server Ingress.
      # That's how the cluster gets ALL the lab's per-tenant Argo apps
      # without tofu touching a single kubectl_manifest — pure GitOps from
      # the moment ArgoCD comes up.
      extraObjects = [
        {
          apiVersion = "argoproj.io/v1alpha1"
          kind       = "Application"
          metadata = {
            name      = "argocd-bootstrap"
            namespace = var.argocd_namespace
            labels = {
              "lab.octopus.com/role" = "argocd-bootstrap"
            }
            # Without this, helm's pre-install/upgrade hook will be GC'd
            # by Argo on the next sync; with it, this Application is a
            # plain resource that survives.
            annotations = {
              "argocd.argoproj.io/sync-options" = "Prune=false"
            }
          }
          spec = {
            project = "default"
            source = {
              repoURL        = "https://github.com/vlussenburg/octopus-iac-lab"
              path           = "gitops/argocd"
              targetRevision = "HEAD"
              directory = {
                recurse = false
              }
            }
            destination = {
              server    = "https://kubernetes.default.svc"
              namespace = var.argocd_namespace
            }
            syncPolicy = {
              automated = {
                prune    = true
                selfHeal = true
              }
              syncOptions = [
                "ApplyOutOfSyncOnly=true",
              ]
            }
          }
        }
      ]
    })
  ]
}

# The chart auto-generates an admin password into argocd-initial-admin-secret
# on first install. We use it to authenticate the argocd provider — works
# the same whether THIS worktree installed argocd or the other one did.
data "kubernetes_secret_v1" "argocd_admin_initial" {
  metadata {
    name      = "argocd-initial-admin-secret"
    namespace = local.argocd_namespace_name
  }

  # Only depend on the helm release if WE installed it. Otherwise the
  # secret is assumed to already exist (the other worktree owns it).
  depends_on = [helm_release.argocd]
}
