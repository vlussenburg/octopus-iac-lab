# Ephemeral Environments: why the project page is empty

The `randomquotes` project's **Ephemeral Environments** page
(`/app#/Spaces-2/projects/randomquotes/ephemeral-environments`) is empty even
though the repo ships preview-env runbooks. The runbooks do real work — they
just never tell Octopus they're the ephemeral-env machinery. Octopus's native
feature is a separate config layer the runbooks don't touch.

## TL;DR

The preview runbooks are plain `kubectl` namespace lifecycle. Octopus's
ephemeral-environments feature is driven by a **channel of type
`EphemeralEnvironment`** plus a **parent environment** and the project's
`ProvisioningRunbookId` / `DeprovisioningRunbookId`. None of that is
configured, so the page stays in its onboarding/empty state. Wire it with one
`octopusdeploy_parent_environment` + an ephemeral `octopusdeploy_channel`
(provider 1.12 has both), or the equivalent `configure` API call. This is a new
feature → its own demo branch, not main.

## What the runbooks do today

`.octopus/runbooks/spin-up-preview.ocl` and `teardown-preview.ocl` (on `main`):

- `Spin up preview` — `kubectl create namespace randomquotes-preview-pr-#{PR.Number}`,
  applies an inlined ConfigMap + Deployment + Service + Ingress for the per-PR
  image `pr-#{PR.Number}`, waits for rollout, echoes the URL.
- `Teardown preview` — `kubectl delete namespace …`.

Fired by `.github/workflows/preview-env.yml` (`run-runbook-action` on PR
opened/closed against `feat/*`). They take `PR.Number` / `PR.Branch` /
`PR.HeadSha` as prompted variables. **They call no Octopus ephemeral-env API.**
They are namespace plumbing that happens to be named "preview".

The Argo side (`gitops/argocd/randomquotes-applicationset-previews.yaml`) is the
parallel GitOps path: a PullRequest-generator ApplicationSet that fans out
`randomquotes-preview-pr-<N>` Applications into `argo-randomquotes-preview-pr-<N>`
namespaces. Also no Octopus ephemeral-env wiring — by design it surfaces under
**Argo CD Instances**, not the ephemeral-env page.

`feat/ephemeral-demo` (PR #25) is **not** unfinished ephemeral infra. It's a
one-line `app/index.html` title change — the trigger-branch demo pattern
("demo branches are 1 surgical commit"). Opening its PR is what fires both
preview paths. The dormancy is just the dormant PR, not missing code.

## How Octopus ephemeral environments actually work

Server `2026.1.11464` (`GET /api` → `Version`). Feature gated behind
`ephemeralEnvironmentsFeatureToggle` (it is on for this build — `configure`
succeeds). The model, from the binaries:

**Entities** (decompiled `Octopus.Core`,
`Octopus.Core.Features.EphemeralEnvironments.MessageContracts`):

- A **Parent Environment** — a special environment created via the
  `parentenvironments` API. It owns an *ephemeral-environment lifecycle*; you
  can't point a channel at an ordinary environment (`configure` rejects it:
  `No ephemeral environment lifecycle found for parent environment`).
- A **Channel** flagged `Type = "EphemeralEnvironment"` carrying
  `ParentEnvironmentId`, `EphemeralEnvironmentNameTemplate`, and
  `AutomaticEphemeralEnvironmentDeployments`. The default channel stays
  `Type = "Lifecycle"`.
- The **project** carries `ProvisioningRunbookId` / `DeprovisioningRunbookId` —
  the runbooks Octopus runs to stand up / tear down each ephemeral env.
- Each live env is a `ProjectEphemeralEnvironment`, provisioned through states
  `NotProvisioned → Provisioning → Provisioned → Deprovisioning → Deprovisioned`.

**The configure command** (`ConfigureEphemeralEnvironmentsBffCommand`, decompiled):

```
ParentEnvironment                       ParentEnvironmentSelection { NewName | ExistingId }   [Required]
EphemeralEnvironmentNameTemplate        string?                                               [Optional]
ProvisioningRunbook                     RunbookSelection { NewName | ExistingId }             [Optional]
DeprovisioningRunbook                   RunbookSelection { NewName | ExistingId }             [Optional]
RunbooksBranch                          string?   (Git ref for CaC runbooks)                  [Optional]
AutomaticEphemeralEnvironmentDeployments bool?                                                [Optional]
```

**Endpoints** (BFF = UI-facing, prefix `/bff/spaces/{spaceId}/`):

- `POST …/projects/{projectId}/ephemeral-environments/configure` — one-shot
  setup (creates/links parent env + ephemeral channel + sets project runbook ids).
- `GET  …/projects/{projectId}/ephemeral-environments?Skip=&Take=` — the page
  feed (`Environments`, `StatusCounts`). Empty here = `TotalResults: 0`.
- `POST …/projects/{projectId}/environments/ephemeral` — provision one.
- `…/environments/ephemeral/{id}/{deprovision,provisioning/retry,…}` — lifecycle.
- Public REST CRUD also exists: `…/parentenvironments` and the channel's
  ephemeral fields (`Type`, `ParentEnvironmentId`, `EphemeralEnvironmentNameTemplate`).

## The gap

The page reads from the configure state. On this project:

- Only channel is `Channels-4 "Default"`, `Type = "Lifecycle"`,
  `ParentEnvironmentId = null`, `EphemeralEnvironmentNameTemplate = null`.
- Project `ProvisioningRunbookId` / `DeprovisioningRunbookId` are null.
- No parent environment exists.

So `GET …/ephemeral-environments` returns `TotalResults: 0` and the UI shows the
onboarding screen. The runbooks run their kubectl independently; nothing
registers them as the project's provisioning/deprovisioning runbooks, and
there's no ephemeral channel for an env to belong to. **The runbooks do
namespace lifecycle; the native feature needs a parent-env + ephemeral-channel +
project runbook bindings. Those don't exist → empty page.**

## The fix

The two existing runbooks are already the right provisioning/deprovisioning
runbooks — they just need to be *registered*. Two ways.

### A. Tofu (preferred — provider 1.12 supports it)

The `octopusdeploy ~> 1.12` provider ships both pieces (confirmed in the
provider binary):

- `octopusdeploy_parent_environment` (`resource_parent_environment.go`).
- `octopusdeploy_channel` with `type` (`"Lifecycle"` | `"EphemeralEnvironment"`),
  `ephemeral_environment_name_template`, `parent_environment_id`,
  `automatic_deprovisioning_rule`.
- Project fields `provisioning_runbook_id` / `deprovisioning_runbook_id`
  (`octopusdeploy_project`).

Sketch (lives on a demo branch, not `app-randomquotes` main wiring):

```hcl
resource "octopusdeploy_parent_environment" "previews" {
  space_id = data.terraform_remote_state.space.outputs.space_id
  name     = "Previews"
}

resource "octopusdeploy_channel" "ephemeral" {
  project_id                          = octopusdeploy_project.randomquotes.id
  name                                = "Ephemeral Environments"
  type                                = "EphemeralEnvironment"
  parent_environment_id               = octopusdeploy_parent_environment.previews.id
  ephemeral_environment_name_template = "preview-pr-#{PR.Number}"
}
```

Bind the runbooks on the project via `provisioning_runbook_id` /
`deprovisioning_runbook_id`. Runbooks are CaC, so look their ids up off the Git
ref (no `octopusdeploy_runbook` data source in 1.12 — same gap as the scheduled
triggers already hit; ids are the slugs `spin-up-preview` / `teardown-preview`).

### B. API workaround (one call, if you'd rather not split across resources)

The `configure` BFF command does parent-env + channel + project bindings
atomically — idiomatic as a `null_resource` + curl, same pattern as
`tofu/control-plane/tenant_logos.tf` and `tofu/platform-hub/`:

```bash
curl -fsS -X POST \
  "$OCTOPUS_URL/bff/spaces/$SPACE/projects/$PROJECT/ephemeral-environments/configure" \
  -H "X-Octopus-ApiKey: $OCTOPUS_API_KEY" -H "Content-Type: application/json" \
  --data '{
    "EphemeralEnvironmentNameTemplate":"preview-pr-#{PR.Number}",
    "ParentEnvironment":{"NewName":"Previews"},
    "ProvisioningRunbook":{"ExistingId":"spin-up-preview"},
    "DeprovisioningRunbook":{"ExistingId":"teardown-preview"},
    "AutomaticEphemeralEnvironmentDeployments":false
  }'
```

`ParentEnvironment` must be `{"NewName":…}` or an existing parent-env id —
not a plain `Environments-N` (that fails the lifecycle check). With existing
runbooks pass `{"ExistingId":"<slug>"}`; omit to have Octopus scaffold new ones.

### Verified against the running instance

Ran option B against `Spaces-2` / `Projects-7` with the two existing runbooks:

```
POST …/ephemeral-environments/configure → 200 {"ChannelName":"Ephemeral Environments"}
```

Result: a new `Channels-82` appeared with `Type = EphemeralEnvironment`,
`ParentEnvironmentId = Environments-21` (the parent env was auto-created and is
hidden from the normal env list), and the project picked up
`ProvisioningRunbookId = spin-up-preview` / `DeprovisioningRunbookId =
teardown-preview`. The page left its empty/onboarding state for the configured
view. **Test entities were cleaned up** (channel deleted, parent env deleted,
project runbook ids nulled) — instance is back to baseline.

Note the catch for the per-PR flow: the env name template uses `#{PR.Number}`,
but provisioning runs the runbook in an ephemeral-env context. The cluster-side
namespace naming (`randomquotes-preview-pr-#{PR.Number}`) already matches, so the
existing runbooks slot in without edits — they just now run *as* the project's
provisioning/deprovisioning hooks instead of being fired manually by GHA.

## House-keeping

- **Demo branch, not main.** Ephemeral envs are a distinct feature demo; per the
  repo's "demo branches are 1 surgical commit on main" rule, this belongs on its
  own `demo/ephemeral-environments` (or extends `feat/ephemeral-demo`), carrying
  only the parent-env + channel + runbook-binding additions. Don't add the
  ephemeral channel to the canonical `randomquotes` project on `main`.
- Prefer option A; fall back to B only if you don't want a separate
  parent-environment resource in state.
- Octopus owns the channel's ephemeral fields in `.octopus/` once the UI touches
  it — don't hand-author them in HCL *and* OCL.
