output "project_url" {
  value       = "${var.octopus_url}/app#/${octopusdeploy_project.randomquotes.space_id}/projects/${octopusdeploy_project.randomquotes.id}/deployments/process"
  description = "Open the randomquotes project in the Octopus UI."
}

output "project_id" {
  value = octopusdeploy_project.randomquotes.id
}
