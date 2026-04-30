output "argocd_url" {
  description = "ArgoCD UI URL (proxy via the cluster's nginx-ingress + port-forward)."
  value       = "http://${var.ingress_host}:8080"
}

output "argocd_admin_password_command" {
  description = "kubectl one-liner that prints the admin password for the Argo UI."
  value       = "kubectl -n ${kubernetes_namespace_v1.argocd.metadata[0].name} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}

output "gateway_release_name" {
  description = "Helm release name for the Octopus Argo CD Gateway. Per-Octopus suffixed."
  value       = local.gateway_release_name
}

output "gateway_namespace" {
  description = "Namespace the Gateway pod lives in."
  value       = kubernetes_namespace_v1.gateway.metadata[0].name
}

output "argocd_application_count" {
  description = "Number of Argo Applications materialised through the local module — should equal tenants × environments."
  value       = length(module.randomquotes_argo_app)
}

output "argocd_application_names" {
  description = "Names of the registered Argo Applications. Each carries argo.octopus.com/* annotations the Gateway forwards to Octopus."
  value       = sort([for app in module.randomquotes_argo_app : app.name])
}
