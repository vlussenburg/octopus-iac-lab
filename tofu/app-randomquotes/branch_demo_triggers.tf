# Project Triggers that auto-create a release when a new randomquotes-image
# is pushed to GHCR. ARC (Automatic Release Creation) is rejected by Octopus
# on VCS projects, so we use a project trigger with FeedFilter + CreateRelease
# instead — same end state, supported on CaC projects.
# Look up each project's default channel — the trigger needs a channel_id
# and Octopus auto-creates exactly one "Default" channel per project.
# `depends_on` defers the read to apply time so the lookup happens AFTER
# the projects exist — without it, the data source runs at plan time on a
# fresh `make apply`, finds zero matching channels, and the downstream
# trigger fails its "channel_id is required" validation.
data "octopusdeploy_channels" "branch_demo_default" {
  for_each = var.demo_branches

  partial_name = "Default"
  ids          = []
  skip         = 0
  take         = 100

  depends_on = [octopusdeploy_project.branch_demo]
}

locals {
  branch_demo_default_channel = {
    for branch, _ in toset(var.demo_branches) :
    branch => one([
      for c in data.octopusdeploy_channels.branch_demo_default[branch].channels :
      c.id if c.project_id == octopusdeploy_project.branch_demo[branch].id
    ])
  }
}

resource "octopusdeploy_external_feed_create_release_trigger" "branch_demo" {
  for_each = var.demo_branches

  name       = "Auto-release on new randomquotes-image"
  space_id   = data.terraform_remote_state.space.outputs.space_id
  project_id = octopusdeploy_project.branch_demo[each.key].id
  channel_id = local.branch_demo_default_channel[each.key]

  package {
    deployment_action_slug = "deploy-manifests"
    package_reference      = "randomquotes-image"
  }
}
