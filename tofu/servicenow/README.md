# tofu/servicenow/

Opt-in stack that drives the Octopus ↔ ServiceNow ITSM integration. Used by [`demo/servicenow-cr-gate`](https://github.com/vlussenburg/octopus-iac-lab/pull/53).

```
make snow-init
make snow-apply TOFU_APPLY_FLAGS=-auto-approve
```

## Prereq: a ServiceNow PDI

Sign up at [`developer.servicenow.com`](https://developer.servicenow.com) and request an instance. Once it boots, drop the URL + admin creds into `.env`:

```
SERVICENOW_URL=https://devXXXXXX.service-now.com
SERVICENOW_USERNAME=admin
SERVICENOW_PASSWORD=<your-pdi-password>
```

## What this stack does

- **PUT `/api/configuration/servicenow-integration/values`** — enables the integration globally and creates one ITSM connection (named `PDI` by default) with basic-auth credentials.
- **PUT the Production environment** — sets `ExtensionSettings` so deployments to Production require an approved ServiceNow Change Request.

Both run as `null_resource` + `local-exec` (the `octopusdeploy` provider has no first-class resources for these yet). The state is idempotent — re-runs PUT the same document.

## How the demo uses this

Once applied:

1. A release auto-deploys to Dev for the three tenants (normal — Dev isn't change-controlled).
2. Promoting that release to Production pauses Octopus, which auto-creates a Normal Change in ServiceNow.
3. Move the change to "Implement" / "Scheduled" in ServiceNow → Octopus polls, picks up the approval, resumes.
4. Octopus writes deployment outcome back to the change as a work note.

Tear down with `make snow-destroy`.
