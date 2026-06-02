output "smoke_test_template_id" {
  value = octopusdeploy_step_template.smoke_test.id
}

output "smoke_test_template_version" {
  value = octopusdeploy_step_template.smoke_test.version
}

output "space_id" {
  value = data.terraform_remote_state.space.outputs.space_id
}
