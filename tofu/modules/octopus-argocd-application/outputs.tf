output "name" {
  description = "Argo Application name as it lives in Kubernetes."
  value       = var.name
}

output "namespace" {
  description = "Namespace of the Application object itself (typically argocd)."
  value       = var.namespace
}

output "manifest" {
  description = "The rendered Application manifest as YAML — useful for debugging or composing app-of-apps roots."
  value       = local.manifest
}

output "octopus_annotations" {
  description = "The argo.octopus.com/* annotations added to the Application — exposed so callers can sanity-check what Octopus will see."
  value       = local.octopus_annotations
}
