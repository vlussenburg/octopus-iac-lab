output "space_id" {
  value       = octopusdeploy_space.this.id
  description = "The Space ID downstream stacks bind their octopusdeploy provider to."
}

output "space_name" {
  value       = octopusdeploy_space.this.name
  description = "The Space name. Used by the k8s-agent helm chart (which wants the name, not the ID)."
}
