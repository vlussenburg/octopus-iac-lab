# ArgoCD itself. Standard upstream chart, with two lab-specific tweaks:
#   1. `octopus` account configured with apiKey-only capability — that's
#      what the Gateway authenticates as.
#   2. RBAC policy granting `octopus` the minimum permissions the Gateway
#      needs (per https://octopus.com/docs/argo-cd/instances/terraform-bootstrap).
#
# The chart's `configs.cm` and `configs.rbac` blocks render into the
# argocd-cm / argocd-rbac-cm ConfigMaps; argocd-server reads them at startup.

resource "kubernetes_namespace_v1" "argocd" {
  metadata {
    name = var.argocd_namespace
  }
}

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = kubernetes_namespace_v1.argocd.metadata[0].name
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
          # `octopus` is the account the Gateway authenticates as. apiKey
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
    })
  ]
}

# The chart auto-generates an admin password into argocd-initial-admin-secret
# on first install. We use it to authenticate the argocd provider.
data "kubernetes_secret_v1" "argocd_admin_initial" {
  metadata {
    name      = "argocd-initial-admin-secret"
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name
  }

  depends_on = [helm_release.argocd]
}
