# Argo UI Ingress on argocd.localtest.me. Routes through the cluster's
# nginx-ingress (installed by tofu/k8s-agent/) so you reach it through the
# same single port-forward that serves all the tenant apps:
#
#   kubectl port-forward svc/ingress-nginx-controller 8080:8080 -n ingress-nginx
#   open http://argocd.localtest.me:8080
#
# argocd-server runs HTTP-only (configs.params.server.insecure=true), so this
# is a vanilla http→http ingress.
resource "kubernetes_ingress_v1" "argocd" {
  count = local.install_argocd_final ? 1 : 0

  metadata {
    name      = "argocd-server"
    namespace = local.argocd_namespace_name
  }

  spec {
    ingress_class_name = "nginx"

    rule {
      host = var.ingress_host
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "argocd-server"
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }

}
