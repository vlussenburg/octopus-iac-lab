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
# channel of Type = EphemeralEnvironment to belong to. The parent env, channel,
# and runbook bindings are provider-native (octopusdeploy ~> 1.12); the
# channel's branch-monitoring fields are not, so they're PATCHed in below.

# The parent environment owns the ephemeral-environment lifecycle; an ephemeral
# channel can't point at an ordinary environment (Dev/Production). Space-level
# resource, but scoped to this project's preview flow so it lives here.
resource "octopusdeploy_parent_environment" "previews" {
  space_id = data.terraform_remote_state.space.outputs.space_id
  name     = "Previews"
}

# Ephemeral channel: every provisioned preview env is created under this
# channel and named from the template. The release number is the pr image tag
# (`1.1.<run>-pr<N>`); stripping everything up to the last `-` yields `pr<N>`,
# so the env name is `preview-pr<N>` — stable per PR, not per build. The
# spin-up-preview runbook parses that name into the namespace + image tag.
#
# The `^pr\d+$` version rule is the inverse of the Default channel's `^$`: it
# claims the pre-release `-pr<N>` images so previews route here, not to Default.
resource "octopusdeploy_channel" "ephemeral_previews" {
  project_id                          = octopusdeploy_project.randomquotes.id
  name                                = "Ephemeral Previews"
  description                         = "Ephemeral preview environments, one per GitHub PR."
  type                                = "EphemeralEnvironment"
  parent_environment_id               = octopusdeploy_parent_environment.previews.id
  ephemeral_environment_name_template = "preview-#{Octopus.Release.Number | Replace \"^.*-\" \"\"}"

  rule {
    tag = "^pr\\d+$"
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
  # Empty: previews are provisioned by build.yml's create-ephemeral-release job
  # (which holds both the PR branch ref and the pr<N> tag), not by Octopus
  # native branch monitoring. Octopus still runs the provisioning runbook when
  # the CI-created release lands on the ephemeral channel.
  ephemeral_git_reference_rules = []
}

# Branch monitoring is what makes Octopus — not a CI workflow — provision a
# preview env per PR. The octopusdeploy provider (~> 1.12) doesn't expose these
# channel fields, so PATCH them in once the channel exists:
#   GitReferenceRules — branch globs Octopus polls for open PRs.
#   AutomaticEphemeralEnvironmentDeployments — provision an ephemeral env per
#   match (runs the provisioning runbook), deprovision on PR close.
# Without these the channel exists but Octopus monitors nothing.
resource "null_resource" "ephemeral_branch_monitoring" {
  triggers = {
    octopus_url = var.octopus_url
    api_key     = var.octopus_api_key
    space_id    = data.terraform_remote_state.space.outputs.space_id
    project_id  = octopusdeploy_project.randomquotes.id
    channel_id  = octopusdeploy_channel.ephemeral_previews.id
    git_rules   = jsonencode(local.ephemeral_git_reference_rules)
  }

  provisioner "local-exec" {
    # GIT_RULES goes via env, not string-interpolated into the python -c arg —
    # the jsonencoded value carries double quotes that would otherwise break
    # the surrounding shell quoting. GET the channel, set the two fields, PUT.
    command = <<-EOT
      set -e
      export GIT_RULES='${self.triggers.git_rules}'
      CH="${self.triggers.octopus_url}/api/${self.triggers.space_id}/projects/${self.triggers.project_id}/channels/${self.triggers.channel_id}"
      BODY=$(curl -sf -H "X-Octopus-ApiKey: ${self.triggers.api_key}" "$CH" | python3 -c 'import sys,json,os; c=json.load(sys.stdin); c["GitReferenceRules"]=json.loads(os.environ["GIT_RULES"]); c["AutomaticEphemeralEnvironmentDeployments"]=True; json.dump(c,sys.stdout)')
      curl -sf -X PUT -H "X-Octopus-ApiKey: ${self.triggers.api_key}" -H "Content-Type: application/json" -d "$BODY" "$CH" >/dev/null
      echo "branch-monitoring set on ${self.triggers.channel_id}: $GIT_RULES"
    EOT
  }
}
