# Two custom user roles for the locked-down-prod-pool demo.
#
# `Developer-Restricted`: project work — read/edit processes, create
#   releases, deploy — but NO Worker*, NO LibraryVariableSetEdit, AND
#   NO VariableEdit. Without WorkerView the pool list is empty in their
#   UI and worker-pool dropdowns are blank. Without LibraryVariableSetEdit
#   they can't flip library-variable-set values. Without VariableEdit
#   they can't touch project-level variables either — which matters
#   because `Project.WorkerPool` lives on the project, and Octopus's API
#   happily accepts PUTs against a CaC project's variables endpoint
#   (Octopus commits the change back via the configured Git credential).
#   Empirically verified during the build: a developer with
#   VariableEdit successfully PUT a tampered Production value and
#   Octopus auto-committed it to the branch. Without VariableEdit, that
#   path is closed. Project variables change via PRs on the OCL file.
#
# `Prod-Deployer`: same project surface area + full Worker* + lib var
#   edit. The role the on-call promoter uses.
#
# Permission names come from `/api/permissions/all` on this Octopus —
# the set is version-dependent. Channels and tag sets are folded into
# ProjectEdit + TargetTagView here, not separate perms.

locals {
  developer_restricted_permissions = [
    "AccountView",
    "ActionTemplateView",
    "ArtifactView",
    "CertificateView",
    "DeploymentCreate",
    "DeploymentView",
    "EnvironmentView",
    "EventView",
    "FeedView",
    "InterruptionSubmit",
    "InterruptionView",
    "LibraryVariableSetView",
    "LifecycleView",
    "MachineView",
    "ProcessEdit",
    "ProcessView",
    "ProjectEdit",
    "ProjectGroupView",
    "ProjectView",
    "ProxyView",
    "ReleaseCreate",
    "ReleaseView",
    "RunbookEdit",
    "RunbookRunCreate",
    "RunbookRunView",
    "RunbookView",
    "SubscriptionView",
    "TargetTagView",
    "TaskView",
    "TenantView",
    "TriggerCreate",
    "TriggerEdit",
    "TriggerView",
    "VariableView",
  ]
}

resource "octopusdeploy_user_role" "developer_restricted" {
  name        = "Developer-Restricted"
  description = "Project edit + release create + deploy. No worker visibility, no library-variable-set edit, no VariableEdit — so they can't pick a pool, change library vars, or PUT a tampered project-level Project.WorkerPool."

  granted_space_permissions = local.developer_restricted_permissions
}

resource "octopusdeploy_user_role" "prod_deployer" {
  name        = "Prod-Deployer"
  description = "Everything Developer-Restricted has, plus WorkerView/WorkerEdit + LibraryVariableSetEdit. The role the promoter / on-call uses to actually ship to Production."

  granted_space_permissions = concat(
    local.developer_restricted_permissions,
    [
      "LibraryVariableSetCreate",
      "LibraryVariableSetEdit",
      "MachineEdit",
      "VariableEdit",
      "WorkerEdit",
      "WorkerView",
    ]
  )
}
