# Explicit Default channels, imported from the ones Octopus auto-creates per
# project, so the stable-only version rule is declarative rather than a runtime
# PATCH.
#
# The rule (pre-release tag `^$`) is what keeps `-pr<N>` preview images off the
# Default channel: the GHCR feed trigger only mints a Default release for
# versions with an empty pre-release tag (stable `1.1.<run>`). PR images carry a
# `-pr<N>` tag, fail the rule, and so route solely to each project's own
# Ephemeral Previews channel instead of fanning out to every project's Dev.

resource "octopusdeploy_channel" "randomquotes_default" {
  name       = "Default"
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
  # The version rule targets the deploy step's package. Most branches share the
  # main OCL shape (Deploy Manifests / randomquotes-image); process-template
  # wraps the deploy in a step template, so its action name + package differ.
  branch_demo_channel_rule_default = {
    deployment_action = "Deploy Manifests"
    package_reference = "randomquotes-image"
  }
  branch_demo_channel_rule_override = {
    "demo/process-template" = {
      deployment_action = "Deploy randomquotes workload"
      package_reference = "AppImage"
    }
  }
}

resource "octopusdeploy_channel" "branch_demo_default" {
  for_each = var.demo_branches

  name       = "Default"
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

# Adopt the auto-created Default channels rather than creating new ones.
import {
  to = octopusdeploy_channel.randomquotes_default
  id = "Channels-4"
}

import {
  to = octopusdeploy_channel.branch_demo_default["demo/blue-green"]
  id = "Channels-81"
}
import {
  to = octopusdeploy_channel.branch_demo_default["demo/bg-preview"]
  id = "Channels-20"
}
import {
  to = octopusdeploy_channel.branch_demo_default["demo/canary"]
  id = "Channels-45"
}
import {
  to = octopusdeploy_channel.branch_demo_default["demo/platform-hub-opa"]
  id = "Channels-44"
}
import {
  to = octopusdeploy_channel.branch_demo_default["demo/process-template"]
  id = "Channels-21"
}
import {
  to = octopusdeploy_channel.branch_demo_default["demo/servicenow-cr-gate"]
  id = "Channels-41"
}
import {
  to = octopusdeploy_channel.branch_demo_default["demo/smoke-step-template"]
  id = "Channels-42"
}
