# Two custom user roles for the locked-down-prod-pool demo.
#
# `Developer-Restricted`: project work — read/edit processes, create
#   releases, deploy — but NO Worker* and NO LibraryVariableSetEdit.
#   Without WorkerView the worker pool list is empty in their UI and
#   worker-pool dropdowns inside step editors are blank. Without
#   LibraryVariableSetEdit they can't flip the env-scoped
#   `Project.WorkerPool` value to escape prod-pool on Production.
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
    "VariableEdit",
    "VariableView",
  ]
}

resource "octopusdeploy_user_role" "developer_restricted" {
  name        = "Developer-Restricted"
  description = "Project edit + release create + deploy. No worker visibility, no library-variable-set edit — so they can't pick a pool or change the env-scoped pool variable."

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
      "WorkerEdit",
      "WorkerView",
    ]
  )
}
