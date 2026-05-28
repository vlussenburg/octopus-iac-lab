# Process-template projects: release auto-versioning

How Octopus picks a release version when a Config-as-Code project's process is a
single `process_template` reference (not inline steps), and the donor-package
config that makes auto-versioning work.

## TL;DR

A CaC project whose process is a `process_template` block expands into child
actions at release time. The donor-package `step` must name the **expanded**
action, not the template-usage block. Use the expanded slug:

```hcl
versioning_strategy {
    donor_package {
        package = "AppImage"
        step    = "deploy-workload-deploy-manifests"   # <usage-slug>-<template-action-slug>
    }
}
```

Not `step = "deploy-workload"` (the usage block) and not `step = "AppImage"`.

## Root cause

### How the version gets resolved

The auto-release feed trigger does **not** call the public `POST /releases`
endpoint. It runs server-side: `FeedTriggerReleaseCreator.CreateRelease`
(`Octopus.Server`, `…ExternalFeedTriggers`) builds a `Release` with
`version: null` and hands it to
`ReleaseCreationFactory.FillAndCreateRelease` (`Octopus.Core`,
`Features.Packages.ReleaseCreation`).

`FillAndCreateSnapshotInternal` then:

1. Expands the process template — `processTemplateStepExpander.Expand(process)` —
   if `process.ProcessTemplateUsages.Any()`. This replaces the single
   `Octopus.ProcessTemplate` placeholder action with the template's real child
   actions.
2. Fills package versions for every expanded package action.
3. Calls `SetVersionFromVersioningStrategy(...)` over
   `expandedProcess.GetAllResolvedEnabledActions().Where(a => a.CanBeUsedForProjectVersioning)`.

`SetVersionFromVersioningStrategy` (donor branch):

```csharp
var versionPackageStep = candidateVersioningSteps
    .GetOrNullByIdOrName(DonorPackage.DeploymentActionId);   // step = ...
if (versionPackageStep == null)
    throw new ReleaseCreationFailedException("Failed to determine the version from package step ...");
var refName = versionPackageStep.Packages.GetByIdOrName(DonorPackage.PackageReferenceId).Name;  // package = ...
release.ChangeVersion(release.SelectedPackages
    .Find(p => p.ActionName == versionPackageStep.Name && refName.Equals(p.PackageReferenceName, ...)).Version);
```

`GetOrNullByIdOrName` matches via `DeploymentAction.IsMatch`, which compares the
donor value against the action **Id** or **Name** only (not slug — but in this
build the expanded action Id equals the expanded slug, so the slug works).

### Why the indirection breaks the obvious config

Before expansion the deployment process has one action:

| | value |
|---|---|
| Id | `deploy-workload` |
| Name | `Deploy randomquotes workload` |
| ActionType | `Octopus.ProcessTemplate` |

So `step = "deploy-workload"` looks right. But the version resolver runs
**after** expansion. The expander (`DeploymentStepProcessTemplateExpander`)
renames every child: `action.Id = stepId + "-" + childId`,
`action.Name = stepName + "-" + childName`. The placeholder `deploy-workload`
no longer exists; the candidates are:

- `deploy-workload-deploy-manifests` / `Deploy randomquotes workload-Deploy Manifests`
- `deploy-workload-update-argo-cd-application-image-tags` / `…-Update Argo CD Application Image Tags`

`GetOrNullByIdOrName("deploy-workload")` finds nothing → throws
`ReleaseCreationFailedException`. The package param name (`AppImage`) is
preserved through expansion, so `package = "AppImage"` was always fine — only
`step` was wrong.

### Why `NextVersionIncrement` is always null here (and that's fine)

The release-template endpoint (`…/deploymentprocesses/template`) reports three
fields. They come from `VersionTemplateCreator.Create`:

- **Donor-package strategy** → sets `VersioningPackageStepName` +
  `VersioningPackageReferenceName`, leaves `NextVersionIncrement` **null**.
- **Version-template strategy** (`release_versioning` with `#{...}`) → sets
  `NextVersionIncrement`, leaves the package fields null.

So `NextVersionIncrement: null` is **normal** for any donor-package project. The
canonical `randomquotes` project (`Projects-7`, plain inline steps, auto-versions
fine) shows the exact same `NextVersionIncrement: null` with
`VersioningPackageStepName: Deploy Manifests`. The real "is it resolving?"
signal is a non-null **`VersioningPackageStepName`**, not `NextVersionIncrement`.

Also note: the public `POST /api/{space}/releases` endpoint can never
auto-version anything — its `CreateReleaseCommand.Version` carries
`[Required(ErrorMessage = "Please provide a version number for this release.")]`.
That's a different code path from the trigger and is expected to demand a
version. Don't use it to test trigger auto-versioning.

## The fix

`.octopus-process-template/deployment_settings.ocl` on `demo/process-template`.

Before (donor names the template-usage block — never matches post-expansion):

```hcl
versioning_strategy {
    donor_package {
        package = "AppImage"
        step    = "deploy-workload"
    }
}
```

After (donor names the expanded action; slug form, stable across renames and
identical to what the trigger filter already uses):

```hcl
versioning_strategy {
    donor_package {
        package = "AppImage"
        step    = "deploy-workload-deploy-manifests"
    }
}
```

### Verified

Template endpoint by commit SHA (bypasses the branch-ref parse cache), channel
`Channels-21`:

```
# before
VersioningPackageStepName:      null
VersioningPackageReferenceName: null

# after
VersioningPackageStepName:      Deploy randomquotes workload-Deploy Manifests
VersioningPackageReferenceName: AppImage
```

Now matches the proven-working canonical project (`Projects-7`), which
auto-versions off its feed trigger. Both correctly report
`NextVersionIncrement: null` (donor strategy).

The `POST /releases` "version-less create" test from the original brief stays
red — by design, that endpoint always requires a version and isn't the path the
trigger uses. The trigger uses `ReleaseCreationFactory.FillAndCreateRelease`,
whose donor lookup is what this fix repairs.

## Notes / limitations

- A donor `step` must match an expanded action by **Id or Name**, not slug per
  se — they coincide in this server build. Prefer the slug form; it survives
  display-name edits. Bump-and-republish a template that renames child steps and
  re-point the donor.
- The slug is `<usage-slug>-<template-step-slug>`, same shape the auto-release
  trigger's `package { deployment_action_slug = ... }` uses
  (`deploy-workload-deploy-manifests`). Keep the two in lock-step.
- Not an Octopus bug — the donor resolver runs against the expanded process by
  design; you just have to name the expanded action.
