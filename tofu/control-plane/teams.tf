# Two demo users + two scoped teams for the locked-down-prod-pool demo.
#
# Each user has a username/password Octopus identity so you can sign in
# directly (no SSO needed in the lab). Lab convenience — both passwords
# are identical to the bootstrap admin; rotate before showing this to
# anyone who isn't you.
#
# The teams use the standalone `octopusdeploy_scoped_user_role` resource
# (NOT inline `user_role` blocks on the team) — the provider docs note
# inline + standalone bindings conflict. We have no env/project/tenant
# scopes on either binding; the entire space is in scope for each role.
# Worker-pool scoping doesn't exist in Octopus at the scoped-role level
# (WorkerView is space-wide on/off) — see worker_pools.tf for the gory
# detail. The demo achieves "developer can't see prod-pool" by giving
# Developer-Restricted no Worker* permission at all.

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
  description = "Project work in the sandbox. No worker pool visibility, no library variable set edit."
  space_id    = data.terraform_remote_state.space.outputs.space_id
  users       = [octopusdeploy_user.developer_demo.id]
}

resource "octopusdeploy_team" "prod_deployers" {
  name        = "prod-deployers"
  description = "Promoters / on-call. Full worker pool visibility + library variable set edit so they can change the env-scoped pool binding."
  space_id    = data.terraform_remote_state.space.outputs.space_id
  users       = [octopusdeploy_user.prod_deployer_demo.id]
}

resource "octopusdeploy_scoped_user_role" "developers" {
  team_id      = octopusdeploy_team.developers.id
  user_role_id = octopusdeploy_user_role.developer_restricted.id
  space_id     = data.terraform_remote_state.space.outputs.space_id
}

resource "octopusdeploy_scoped_user_role" "prod_deployers" {
  team_id      = octopusdeploy_team.prod_deployers.id
  user_role_id = octopusdeploy_user_role.prod_deployer.id
  space_id     = data.terraform_remote_state.space.outputs.space_id
}
