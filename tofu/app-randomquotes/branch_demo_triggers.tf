# Project Triggers that auto-create a release when a new randomquotes-image
# is pushed to GHCR. ARC (Automatic Release Creation) is rejected by Octopus
# on VCS projects, so we use a project trigger with FeedFilter + CreateRelease
# instead — same end state, supported on CaC projects.
#
# Each project's Default channel (channels.tf) carries the stable-only version
# rule, so these triggers ignore `-pr<N>` preview images.

# Per-branch overrides for the trigger's action slug + package reference.
# Branches whose deployment process uses a `process_template` usage need the
# EXPANDED step slug (`{template-usage-slug}-{step-in-template-slug}`) — not
# the usage label — and the package reference name comes from the template's
# `package_parameter`. Discoverable via:
#   GET /api/Spaces-{S}/projects/{P}/{commitSha}/deploymentprocesses/resolved
# (each Steps[].Actions[].Slug is the value to use as deployment_action_slug.)
locals {
  branch_demo_trigger_override = {
    "demo/process-template" = {
      deployment_action_slug = "deploy-workload-deploy-manifests"
      package_reference      = "AppImage"
    }
  }
  branch_demo_trigger_default = {
    deployment_action_slug = "deploy-manifests"
    package_reference      = "randomquotes-image"
  }
}

resource "octopusdeploy_external_feed_create_release_trigger" "branch_demo" {
  for_each = var.demo_branches

  name       = "Auto-release on new randomquotes-image"
  space_id   = data.terraform_remote_state.space.outputs.space_id
  project_id = octopusdeploy_project.branch_demo[each.key].id
  channel_id = octopusdeploy_channel.branch_demo_default[each.key].id

  package {
    deployment_action_slug = lookup(local.branch_demo_trigger_override, each.key, local.branch_demo_trigger_default).deployment_action_slug
    package_reference      = lookup(local.branch_demo_trigger_override, each.key, local.branch_demo_trigger_default).package_reference
  }
}
