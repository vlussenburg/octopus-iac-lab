output "argocd_url" {
  description = "ArgoCD UI URL (proxy via the cluster's nginx-ingress + port-forward)."
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

output "app_of_apps_root" {
  description = "Argo App-of-Apps root Application created for this worktree. Argo materialises the six leaf Applications from gitops/applications/randomquotes/<source>/ on next sync."
  value       = "randomquotes-root-${local.target_kind}"
}

output "leaf_apps_source_path" {
  description = "Repo path the App-of-Apps root watches. Edits here propagate to the cluster on Argo's next poll."
  value       = "gitops/applications/randomquotes/${local.target_kind}"
}
