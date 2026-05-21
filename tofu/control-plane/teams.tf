locals {
  demo_user_password = "Password01!"
}

resource "octopusdeploy_user" "developer_demo" {
  username      = "developer"
  display_name  = "Developer Demo"
  email_address = "developer@lab.local"
  password      = local.demo_user_password
  is_active     = true
  is_service    = false
}

resource "octopusdeploy_user" "prod_deployer_demo" {
  username      = "prod-deployer"
  display_name  = "Prod-Deployer Demo"
  email_address = "prod-deployer@lab.local"
  password      = local.demo_user_password
  is_active     = true
  is_service    = false
}

resource "octopusdeploy_team" "developers" {
  name        = "developers"
  description = "Project viewer + Environment viewer + Deployment creator (Dev only) + Release creator + GitCredentialView/VariableView overlay."
  space_id    = data.terraform_remote_state.space.outputs.space_id
  users       = [octopusdeploy_user.developer_demo.id]
}

resource "octopusdeploy_team" "prod_deployers" {
  name        = "prod-deployers"
  description = "Project lead + Deployment creator + Environment manager."
  space_id    = data.terraform_remote_state.space.outputs.space_id
  users       = [octopusdeploy_user.prod_deployer_demo.id]
}

resource "octopusdeploy_scoped_user_role" "developers_project_viewer" {
  team_id      = octopusdeploy_team.developers.id
  user_role_id = "userroles-projectviewer"
  space_id     = data.terraform_remote_state.space.outputs.space_id
}

resource "octopusdeploy_scoped_user_role" "developers_environment_viewer" {
  team_id      = octopusdeploy_team.developers.id
  user_role_id = "userroles-environmentviewer"
  space_id     = data.terraform_remote_state.space.outputs.space_id
}

resource "octopusdeploy_scoped_user_role" "developers_deployment_creator" {
  team_id         = octopusdeploy_team.developers.id
  user_role_id    = "userroles-deploymentcreator"
  space_id        = data.terraform_remote_state.space.outputs.space_id
  environment_ids = [octopusdeploy_environment.dev.id]
}

resource "octopusdeploy_scoped_user_role" "developers_release_creator" {
  team_id      = octopusdeploy_team.developers.id
  user_role_id = "userroles-releasecreator"
  space_id     = data.terraform_remote_state.space.outputs.space_id
}

resource "octopusdeploy_scoped_user_role" "developers_addon" {
  team_id      = octopusdeploy_team.developers.id
  user_role_id = octopusdeploy_user_role.developer_addon.id
  space_id     = data.terraform_remote_state.space.outputs.space_id
}

resource "octopusdeploy_scoped_user_role" "prod_deployers_project_lead" {
  team_id      = octopusdeploy_team.prod_deployers.id
  user_role_id = "userroles-projectlead"
  space_id     = data.terraform_remote_state.space.outputs.space_id
}

resource "octopusdeploy_scoped_user_role" "prod_deployers_deployment_creator" {
  team_id      = octopusdeploy_team.prod_deployers.id
  user_role_id = "userroles-deploymentcreator"
  space_id     = data.terraform_remote_state.space.outputs.space_id
}

resource "octopusdeploy_scoped_user_role" "prod_deployers_environment_manager" {
  team_id      = octopusdeploy_team.prod_deployers.id
  user_role_id = "userroles-environmentmanager"
  space_id     = data.terraform_remote_state.space.outputs.space_id
}
