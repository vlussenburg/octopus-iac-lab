output "name" {
  description = "Gateway name as it lives in Octopus."
  value       = var.name
}

output "namespace" {
  description = "Kubernetes namespace the gateway pod runs in."
  value       = kubernetes_namespace_v1.this.metadata[0].name
}

output "release_name" {
  description = "Helm release name."
  value       = helm_release.this.name
}
