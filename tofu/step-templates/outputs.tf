output "smoke_test_template_id" {
  value       = octopusdeploy_step_template.smoke_test.id
  description = "Action template Id (per-space). Use in OCL invocations as Octopus.Action.Template.Id."
}

output "smoke_test_template_name" {
  value       = octopusdeploy_step_template.smoke_test.name
  description = "Display name."
}

output "smoke_test_template_version" {
  value       = octopusdeploy_step_template.smoke_test.version
  description = "Auto-bumped on every Properties/Parameters change. Consumers pin to a version."
}

output "space_id" {
  value       = data.terraform_remote_state.space.outputs.space_id
  description = "Space the template lives in."
}
