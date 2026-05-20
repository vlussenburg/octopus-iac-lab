# tofu/step-templates

Library step templates (custom action templates) authored once and
registered into the Sandbox Space. Demonstrates the **innermost ring**
of the lab's templating nesting-doll: step template → process template
→ project. A platform-engineer authors the step once with thresholds +
inputs parameterized; app teams adopt it without re-implementing the
script.

## Why this isn't in Platform Hub

Custom action templates live at `/api/Spaces-{n}/actiontemplates` —
per-space. Platform Hub hosts **Process Templates** (collections of
steps, cross-space) but not single step templates. The Octopus answer
to "cross-space reusable steps" today is either:

- a **Community Action Template** (curated, read-only catalog), or
- a single Library step template registered identically per space.

This stack is the latter — apply it against each Space that wants the
step available. Idempotent: re-running matches state, no churn.

## Provider note

`octopusdeploy_step_template` ships in `OctopusDeploy/octopusdeploy
~> 1.13` (the same release also added `octopusdeploy_process_step` and
`octopusdeploy_process_templated_step` — handy for typed deployment
process authoring). Earlier provider versions had nothing for this and
forced a `null_resource + curl POST /api/Spaces-{n}/actiontemplates`
shape.

The `parameters[*].id` UUIDs are pinned in HCL so re-applies don't
rotate them — Octopus keys per-step parameter bindings off the UUID,
so rotation = silently breaking every consumer's bound values.

## What's registered

| Template | Type | Inputs | Where |
|---|---|---|---|
| `Smoke Test - HTTP` | `Octopus.Script` (Bash) | 8 parameters (see below) | Library → Step Templates |

### Parameters

| Name | Default | Notes |
|---|---|---|
| `BaseUrl` | _required_ | Scheme + host + optional port. Example: `http://#{AppName}.#{Namespace}.svc.cluster.local`. |
| `Path` | `/` | Path appended to `BaseUrl`. |
| `Iterations` | `20` | Number of requests. |
| `ExpectedStatus` | `200` | Each iteration must return this status. |
| `MaxLatencyMs` | `500` | Per-request latency ceiling; slower requests count as failures. |
| `MinSuccessPct` | `95` | Step fails if pass-rate below this. |
| `WarmupSeconds` | `5` | Sleep before first request — Service endpoints / ingress controllers need time to settle. |
| `ExpectBody` | _(empty)_ | Optional substring; if set, response body must contain it. Catches 200-OK-but-wrong-page regressions. |

The script body lives in `scripts/smoke-test.sh` and is read at apply
time via `file()` — edit there, re-apply, the template updates in
place (re-publish bumps the in-Octopus version automatically).

## Applying

The stack is not wired into the root `Makefile` (demo branches don't
drift the Makefile). Apply manually after the `space` stack:

```bash
source .env
cd tofu/step-templates
tofu init
TF_VAR_octopus_url="$OCTOPUS_URL" \
TF_VAR_octopus_api_key="$OCTOPUS_API_KEY" \
  tofu apply
```

Re-run anytime — `tofu plan` is a no-op when the script + parameters
haven't changed.

`tofu destroy` removes the template; consumers that still reference it
will fail at process-validation time, so destroy *after* removing the
step from any consuming projects.

## Consuming the step in a project

From the Octopus UI:

1. Open the project's deployment process.
2. **Add step** → search for `Smoke Test - HTTP` → pick it.
3. Fill in `BaseUrl` (typically the in-cluster Service URL from the
   preceding `Octopus.KubernetesDeployRawYaml` step), `ExpectBody`
   (e.g. the rendered tenant name), and tweak thresholds per tier.

The OCL serialization Octopus writes back looks like this (action
template Ids are space-scoped, so they differ between local and SaaS;
the slug doesn't survive `Octopus.Action.Template.Id` either — at the
moment the OCL is instance-specific for custom templates):

```hcl
step "smoke-test" {
    name = "Smoke test"
    properties = {
        Octopus.Action.TargetRoles = "k8s"
    }

    action {
        action_type = "Octopus.Script"
        properties = {
            Octopus.Action.Template.Id      = "ActionTemplates-<id>"  # per-space
            Octopus.Action.Template.Version = "1"
            BaseUrl                         = "http://randomquotes.randomquotes-#{Source}-#{Octopus.Deployment.Tenant.Name}-#{Octopus.Environment.Name | ToLower}.svc.cluster.local"
            ExpectBody                      = "#{Octopus.Deployment.Tenant.Name}"
            MaxLatencyMs                    = "#{if Octopus.Deployment.Tenant.Tags[\"tier\"] == \"enterprise\"}300#{else}1500#{/if}"
        }
    }
}
```

The per-space ID is the friction point: a fully-portable CaC reference
to a custom template across instances needs either a Community
Action Template (read-only) or the upcoming Platform Hub step-template
surface (not in 2026.1.x).

## Notes

- `Octopus.Action.RunOnServer = "true"` runs the step on the Octopus
  built-in worker. For in-cluster Service URLs (the typical use here),
  the consuming step should set `Octopus.Action.TargetRoles = "k8s"`
  so it runs inside the K8s agent's worker and DNS resolves.
- Latency thresholds default to lab-friendly values (500ms, 95%) —
  consumers tighten via per-tenant / per-env variables.
- The script's only external dependency is `curl + awk` — both
  present in every Octopus worker and the lab's K8s agent image.
