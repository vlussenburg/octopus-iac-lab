# Our own stable channel, created (not adopted) so the config bootstraps any
# instance with a plain `apply` — no per-instance channel IDs, no import step.
# Octopus auto-creates a "Default" channel per project and that channel owns the
# slug "default" from birth; a second channel can't reuse the name or slug, so
# instead we create "Stable" (slug "stable"), mark it default, and leave the
# auto-created "Default" orphaned (non-default, unused). Nothing routes a release
# to "Default" (no trigger, not is_default), so it never deploys.
#
# The rule (pre-release tag `^$`) keeps `-pr<N>` preview images off the stable
# channel: the GHCR feed trigger only mints a stable release for versions with
# an empty pre-release tag (`1.1.<run>`). PR images carry a `-pr<N>` tag, fail
# the rule, and route solely to each project's own Ephemeral Previews channel.

resource "octopusdeploy_channel" "randomquotes_stable" {
  name       = "Stable"
  project_id = octopusdeploy_project.randomquotes.id
  is_default = true

  rule {
    tag = "^$"
    action_package {
      deployment_action = "Deploy Manifests"
      package_reference = "randomquotes-image"
    }
    action_package {
      deployment_action = "Update Argo CD Application Image Tags"
      package_reference = "octopus-iac-lab"
    }
  }
}

locals {
  # The `^$` rule constrains only the action+package references it names. ANY
  # image-bearing action it omits stays unconstrained, so the feed trigger fills
  # that one from the newest tag (a `-pr<N>` preview) and the release lands on the
  # stable channel anyway. So every action that consumes the image must be listed
  # — branches with a single deploy action need one entry; branches that deploy
  # the image from several actions (e.g. two delivery strategies plus an Argo tag
  # update) need all of them, or the uncovered action leaks the preview.
  branch_demo_channel_rule_default = [
    { deployment_action = "Deploy Manifests", package_reference = "randomquotes-image" },
  ]
  branch_demo_channel_rule_override = {
    "demo/canary" = [
      { deployment_action = "Deploy Manifests (Dev Plain)", package_reference = "randomquotes-image" },
      { deployment_action = "Deploy Manifests (Production Canary)", package_reference = "randomquotes-image" },
      { deployment_action = "Update Argo CD Application Image Tags", package_reference = "octopus-iac-lab" },
    ]
    "demo/blue-green" = [
      { deployment_action = "Deploy (Rolling)", package_reference = "randomquotes-image" },
      { deployment_action = "Deploy (Blue/Green)", package_reference = "randomquotes-image" },
      { deployment_action = "Update Argo CD Application Image Tags", package_reference = "octopus-iac-lab" },
    ]
    "demo/process-template" = [
      { deployment_action = "Deploy randomquotes workload-Deploy Manifests", package_reference = "AppImage" },
      { deployment_action = "Deploy randomquotes workload-Update Argo CD Application Image Tags", package_reference = "AppImage" },
    ]
    "demo/smoke-step-template" = [
      { deployment_action = "Deploy Manifests", package_reference = "randomquotes-image" },
      { deployment_action = "Update Argo CD Application Image Tags", package_reference = "octopus-iac-lab" },
    ]
    "demo/bg-preview" = [
      { deployment_action = "Deploy Manifests", package_reference = "randomquotes-image" },
      { deployment_action = "Deploy Manifests (Dev plain Deployment)", package_reference = "randomquotes-image" },
      { deployment_action = "Update Argo CD Application Image Tags", package_reference = "octopus-iac-lab" },
    ]
  }
}

resource "octopusdeploy_channel" "branch_demo_stable" {
  for_each = var.demo_branches

  name       = "Stable"
  project_id = octopusdeploy_project.branch_demo[each.key].id
  is_default = true

  rule {
    tag = "^$"
    dynamic "action_package" {
      for_each = lookup(local.branch_demo_channel_rule_override, each.key, local.branch_demo_channel_rule_default)
      content {
        deployment_action = action_package.value.deployment_action
        package_reference = action_package.value.package_reference
      }
    }
  }
}

# Demo branch OCL references channel "ephemeral-previews" exactly like the main
# randomquotes OCL, but only the main project got an ephemeral channel
# (ephemeral.tf) — leaving the slug unresolvable on every per-branch demo
# project. Mirror it per branch, reusing the same image-bearing action map as
# the stable channel so the `^pr<N>` rule covers the same actions.
#
# This channel exists ONLY so the slug resolves — it must never provision a
# preview env (the feat/* preview demo runs on the main randomquotes project
# alone). The provider defaults EphemeralEnvironment channels to
# AutomaticEphemeralEnvironmentDeployments=true, which we deliberately leave on:
# it's an inert footgun here because demo projects have no feed/auto-release
# trigger pointing at this channel and build.yml's create-ephemeral-release is
# pinned to project randomquotes — so no release ever reaches it to act on.
resource "octopusdeploy_channel" "branch_demo_ephemeral_previews" {
  for_each = var.demo_branches

  project_id                          = octopusdeploy_project.branch_demo[each.key].id
  name                                = "Ephemeral Previews"
  description                         = "Ephemeral preview environments, one per GitHub PR."
  type                                = "EphemeralEnvironment"
  parent_environment_id               = octopusdeploy_parent_environment.previews.id
  ephemeral_environment_name_template = "preview-#{Octopus.Release.Number | Replace \"^.*-\" \"\"}"

  rule {
    tag = "^pr\\d+$"
    dynamic "action_package" {
      for_each = lookup(local.branch_demo_channel_rule_override, each.key, local.branch_demo_channel_rule_default)
      content {
        deployment_action = action_package.value.deployment_action
        package_reference = action_package.value.package_reference
      }
    }
  }
}
