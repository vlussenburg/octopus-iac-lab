# Native Ephemeral Environments wiring for the randomquotes project.
#
# The repo already ships the namespace-lifecycle runbooks (spin-up-preview /
# teardown-preview in .octopus/runbooks/), but Octopus's native ephemeral-env
# feature was unconfigured: no parent environment, no ephemeral-type channel,
# and the project's provisioning/deprovisioning runbook bindings were null — so
# the project's Ephemeral Environments page sat in its empty onboarding state.
#
# This registers the existing runbooks as the project's provisioning/
# deprovisioning hooks and gives ephemeral envs a parent environment + a
# channel of Type = EphemeralEnvironment to belong to. All three pieces are
# provider-native in octopusdeploy ~> 1.12 — no curl/BFF workaround needed.

# The parent environment owns the ephemeral-environment lifecycle; an ephemeral
# channel can't point at an ordinary environment (Dev/Production). Space-level
# resource, but scoped to this project's preview flow so it lives here.
resource "octopusdeploy_parent_environment" "previews" {
  space_id = data.terraform_remote_state.space.outputs.space_id
  name     = "Previews"
}

# Ephemeral channel: every provisioned preview env is created under this
# channel and named from the template. #{PR.Number} matches the namespace
# naming the spin-up-preview runbook already uses
# (randomquotes-preview-pr-#{PR.Number}), so the existing runbooks slot in as
# the provisioning/deprovisioning hooks without edits.
resource "octopusdeploy_channel" "ephemeral_previews" {
  project_id                          = octopusdeploy_project.randomquotes.id
  name                                = "Ephemeral Previews"
  description                         = "Ephemeral preview environments, one per GitHub PR."
  type                                = "EphemeralEnvironment"
  parent_environment_id               = octopusdeploy_parent_environment.previews.id
  ephemeral_environment_name_template = "preview-pr-#{PR.Number}"
}
