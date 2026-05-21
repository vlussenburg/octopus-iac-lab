# Two demo users + two scoped teams for the locked-down-prod-pool demo.
#
# Each user has a username/password Octopus identity so you can sign in
# directly (no SSO needed in the lab). Lab convenience — both passwords
# are identical to the bootstrap admin; rotate before showing this to
# anyone who isn't you.
#
# The teams use the standalone `octopusdeploy_scoped_user_role` resource
# (NOT inline `user_role` blocks on the team) — the provider docs note
# inline + standalone bindings conflict. The `developers` binding scopes
# the role to the `Dev` environment so devs can deploy to Dev but not
# Production (scope applies to env-aware permissions: DeploymentCreate,
# DeploymentView, etc.; everything else stays space-wide). The
# `prod-deployers` binding is unscoped — they ship to any environment.
# Worker-pool scoping doesn't exist at the scoped-role level
# (`WorkerView`/`WorkerEdit` are space-wide on/off — see
# worker_pools.tf); that gap is structurally only fillable by OPA
# process-validation, not RBAC.

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
  description = "Project authors. Deploy to Dev (env-scoped via the scoped role binding below); read-only WorkerView. No deploy to Production, no WorkerEdit, no LibraryVariableSetEdit, no VariableEdit. ProcessEdit means they can still hand-pin any pool on their steps — only OPA process-validation closes that."
  space_id    = data.terraform_remote_state.space.outputs.space_id
  users       = [octopusdeploy_user.developer_demo.id]
}

resource "octopusdeploy_team" "prod_deployers" {
  name        = "prod-deployers"
  description = "Promoters / on-call. Full Worker* + LibraryVariableSetEdit + VariableEdit. The role that owns the env-scoped pool binding and can change worker registration."
  space_id    = data.terraform_remote_state.space.outputs.space_id
  users       = [octopusdeploy_user.prod_deployer_demo.id]
}

resource "octopusdeploy_scoped_user_role" "developers" {
  team_id      = octopusdeploy_team.developers.id
  user_role_id = octopusdeploy_user_role.developer_restricted.id
  space_id     = data.terraform_remote_state.space.outputs.space_id

  # Env-axis restriction. Permissions in the role that recognise
  # Environment as a scope dimension (DeploymentCreate, DeploymentView,
  # interruption submission, etc.) become "Dev only" for this team.
  # Permissions with no Environment scope dimension (ProcessEdit,
  # ProjectView, VariableView, GitCredentialView, ...) remain
  # space-wide. Net effect: developer can ship to Dev, can't ship to
  # Production.
  environment_ids = [octopusdeploy_environment.dev.id]
}

resource "octopusdeploy_scoped_user_role" "prod_deployers" {
  team_id      = octopusdeploy_team.prod_deployers.id
  user_role_id = octopusdeploy_user_role.prod_deployer.id
  space_id     = data.terraform_remote_state.space.outputs.space_id
}
