# Our own stable channel, created (not adopted) so the config bootstraps any
# instance with a plain `apply` — no per-instance channel IDs, no import step.
# Octopus auto-creates a "Default" channel per project and that channel owns the
# slug "default" from birth; a second channel can't reuse the name or slug, so
# instead we create "Stable" (slug "stable"), mark it default, and leave the
# auto-created "Default" orphaned (non-default, unused). The deployment OCL
# scopes its steps to channel "stable" to match.
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
  }
}

locals {
  # The version rule binds to a named deploy step's package — if that step name
  # doesn't exist in the branch's process, Octopus silently ignores the rule and
  # the feed trigger lets `-pr<N>` preview images leak onto the demo's stable
  # channel. Branches that rename/wrap the deploy step must therefore name a step
  # that actually exists; the rule rejects the whole release when that step's
  # package fails `^$`, so one real image step per branch is enough.
  branch_demo_channel_rule_default = {
    deployment_action = "Deploy Manifests"
    package_reference = "randomquotes-image"
  }
  branch_demo_channel_rule_override = {
    "demo/canary" = {
      deployment_action = "Deploy Manifests (Dev Plain)"
      package_reference = "randomquotes-image"
    }
    "demo/blue-green" = {
      deployment_action = "Deploy (Rolling)"
      package_reference = "randomquotes-image"
    }
    "demo/process-template" = {
      deployment_action = "Deploy randomquotes workload-Deploy Manifests"
      package_reference = "AppImage"
    }
  }
}

resource "octopusdeploy_channel" "branch_demo_stable" {
  for_each = var.demo_branches

  name       = "Stable"
  project_id = octopusdeploy_project.branch_demo[each.key].id
  is_default = true

  rule {
    tag = "^$"
    action_package {
      deployment_action = lookup(local.branch_demo_channel_rule_override, each.key, local.branch_demo_channel_rule_default).deployment_action
      package_reference = lookup(local.branch_demo_channel_rule_override, each.key, local.branch_demo_channel_rule_default).package_reference
    }
  }
}
