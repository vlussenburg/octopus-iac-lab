# .octopus/

This folder is **owned by Octopus**. Once Terraform creates the version-controlled project, Octopus serialises the project's deployment process, channels, non-sensitive variables, and runbooks into `.ocl` files here whenever you save changes in the UI.

The folder name is fixed: Octopus enforces `.octopus` as the base path and rejects anything else. (Yes, this is the only place dotfiles get checked in on purpose.)

You can edit OCL by hand, commit, push — Octopus will pick it up. Or edit in the UI — Octopus will commit on your behalf using the configured Git credential.

## Expected structure (Octopus generates this on first save)

```
.octopus/
├── deployment_process.ocl
├── deployment_settings.ocl
├── variables.ocl
└── runbooks/
    └── <runbook-name>.ocl
```

Empty until then. Don't pre-populate — let Octopus seed it so the format matches the running server's version.

## Why this is in the same repo as the OpenTofu

- One source of truth for the project's existence (Tofu) **and** its config (OCL).
- `tofu apply` plus a `git push` of `.octopus/` together describe the full project state.
- Customers usually split this — IaC in an "infra" repo, OCL in the app repo. The lab keeps it together for reading clarity.
