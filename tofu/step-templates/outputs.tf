# Action template IDs aren't returned via the null_resource — querying the
# API surface a sibling stack would consume is left to the consumer (UI or
# `curl /api/Spaces-{id}/actiontemplates?partialName=Smoke+Test+-+HTTP`).
# If a future provider release ships `octopusdeploy_action_template`, swap
# the null_resource for it and add Id/Slug outputs here.

output "smoke_test_template_name" {
  value       = local.smoke_test_template_name
  description = "Display name of the Library step template registered by this stack."
}

output "space_id" {
  value       = data.terraform_remote_state.space.outputs.space_id
  description = "Space the templates live in."
}
