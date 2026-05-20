# tofu/step-templates

Library step templates (custom action templates) authored once and
registered into the Sandbox Space. Demonstrates the **innermost ring**
of the lab's templating nesting-doll: step template → process template
→ project. A platform-engineer authors the step once with thresholds +
inputs parameterized; app teams adopt it without re-implementing the
script.

## Why this isn't in Platform Hub

Custom action templates are per-space (`/api/Spaces-{n}/actiontemplates`),
stored in the Octopus DB. PH hosts **Process Templates** (collections
of steps, cross-space) — not single step templates. To make this step
available in another space, apply the stack against that space too.

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

Script body lives in `scripts/smoke-test.sh`, read at apply time via
`file()`.

## Applying

Not wired into the root `Makefile` (demo branches don't drift it).
Apply manually after the `space` stack:

```bash
source .env
cd tofu/step-templates
tofu init
TF_VAR_octopus_url="$OCTOPUS_URL" \
TF_VAR_octopus_api_key="$OCTOPUS_API_KEY" \
  tofu apply
```

## Consuming the step in a project

From the UI: project → **Process** → **Add Step** → search `Smoke
Test - HTTP`.

OCL serialization Octopus writes back:

```hcl
step "smoke-test" {
    name = "Smoke test"
    properties = {
        Octopus.Action.TargetRoles = "k8s"
    }

    action {
        action_type = "Octopus.Script"
        properties = {
            Octopus.Action.Template.Id      = "ActionTemplates-<id>"
            Octopus.Action.Template.Version = "1"
            BaseUrl                         = "http://randomquotes.#{Namespace}.svc.cluster.local"
            ExpectBody                      = "#{Octopus.Deployment.Tenant.Name}"
        }
    }
}
```

`Octopus.Action.Template.Id` is space-scoped — the committed OCL doesn't
round-trip between local↔SaaS for custom templates.

Set `Octopus.Action.TargetRoles = "k8s"` on the consuming step so it
runs inside the K8s agent's worker (in-cluster Service DNS).
