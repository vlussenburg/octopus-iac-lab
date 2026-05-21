# Two custom user roles for the locked-down-prod-pool demo.
#
# `Developer-Restricted`: project work — read/edit processes, create
#   releases, deploy — and read-only WorkerView (browse the pool list,
#   see who's healthy) but NO WorkerEdit, NO LibraryVariableSetEdit,
#   and NO VariableEdit.
#
#   Things that DO stop a malicious dev:
#     - Without VariableEdit they can't PUT a tampered Project.WorkerPool
#       to the CaC project's variables endpoint. (Octopus's API DOES
#       accept variable writes against VCS projects and auto-commits
#       them back via the configured Git credential — empirically
#       verified during the build before this gate was added.)
#     - Without LibraryVariableSetEdit they can't change library-set
#       values either.
#
#   Things that DON'T stop them — and there's no Octopus-side fix:
#     - ProcessEdit lets them assign any pool to any step they own.
#       Octopus has no per-pool ACL at the process-edit layer; WorkerView
#       is space-wide (RestrictedTo: []) and so is its read counterpart.
#       The only true gate against "dev pins prod-pool on their own step"
#       is Platform Hub process-validation policy — the Rego rule on
#       demo/platform-hub-opa is the placeholder for that, awaiting
#       Octopus's provider exposing the resource.
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
    "GitCredentialView",
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
    "WorkerView",
  ]
}

resource "octopusdeploy_user_role" "developer_restricted" {
  name        = "Developer-Restricted"
  description = "Project edit + release create + deploy. Read-only WorkerView (can browse pools) but no WorkerEdit, LibraryVariableSetEdit, or VariableEdit — so they can't tamper with library variables, project-level variables (incl. Project.WorkerPool), or worker config. ProcessEdit still allows them to pin any pool on their own steps; that gap is closed by Platform Hub process-validation policy, not by Octopus RBAC."

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
    ]
  )
}
