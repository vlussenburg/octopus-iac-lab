# Auto-create a release on the main `randomquotes` project whenever a new
# randomquotes-image is pushed to GHCR. Mirrors the trigger pattern already
# applied to every demo branch project in branch_demo_triggers.tf, so all
# projects converge on the same image-detection release-creation model.
#
# This is what lets `.github/workflows/build.yml` be a pure image-builder —
# CI no longer needs `OctopusDeploy/create-release-action` to mint releases
# explicitly. Octopus polls the GHCR feed (~30s cadence) and creates a
# release with the image tag as the release version automatically.
#
# Auto-deploy to Dev fires via the lifecycle's `AutomaticDeploymentTargets`
# (see control-plane/lifecycle.tf) — no CI deploy step needed either.
data "octopusdeploy_channels" "randomquotes_default" {
  partial_name = "Default"
  ids          = []
  skip         = 0
  take         = 100

  depends_on = [octopusdeploy_project.randomquotes]
}

locals {
  randomquotes_default_channel_id = one([
    for c in data.octopusdeploy_channels.randomquotes_default.channels :
    c.id if c.project_id == octopusdeploy_project.randomquotes.id
  ])
}

resource "octopusdeploy_external_feed_create_release_trigger" "randomquotes" {
  name       = "Auto-release on new randomquotes-image"
  space_id   = data.terraform_remote_state.space.outputs.space_id
  project_id = octopusdeploy_project.randomquotes.id
  channel_id = local.randomquotes_default_channel_id

  package {
    deployment_action_slug = "deploy-manifests"
    package_reference      = "randomquotes-image"
  }
}
