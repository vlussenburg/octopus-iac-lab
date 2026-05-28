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

locals {
  # Branch globs Octopus watches to auto-provision a preview per PR. Matches
  # build.yml's pr-<N> image build, which fires on feat/* PRs.
  ephemeral_git_reference_rules = ["refs/heads/feat/*"]
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
