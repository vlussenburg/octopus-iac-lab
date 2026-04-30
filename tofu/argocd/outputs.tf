output "argocd_url" {
  description = "ArgoCD UI URL (proxy via the cluster's nginx-ingress + port-forward). The Ingress itself is materialised by Argo from gitops/argocd/."
  value       = "http://${var.ingress_host}:8080"
}

output "argocd_admin_password_command" {
  description = "kubectl one-liner that prints the admin password for the Argo UI."
  value       = "kubectl -n ${local.argocd_namespace_name} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}

output "gateway_name" {
  description = "Octopus-side name of the registered Argo CD Gateway."
  value       = module.gateway.name
}

output "gateway_namespace" {
  description = "Namespace the Gateway pod runs in."
  value       = module.gateway.namespace
}
