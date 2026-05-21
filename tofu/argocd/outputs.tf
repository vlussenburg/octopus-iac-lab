output "argocd_url" {
  description = "ArgoCD UI URL (proxy via the cluster's nginx-ingress + port-forward). The Ingress itself is materialised by Argo from gitops/argocd/."
  value       = "http://${var.ingress_host}:8080"
}

output "argocd_admin_login" {
  description = "ArgoCD UI admin login. Password is set statically in the helm release."
  value       = "admin / ${var.argocd_password}"
  sensitive   = true
}

output "gateway_name" {
  description = "Octopus-side name of the registered Argo CD Gateway."
  value       = module.gateway.name
}

output "gateway_namespace" {
  description = "Namespace the Gateway pod runs in."
  value       = module.gateway.namespace
}
