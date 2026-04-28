# octopus-iac-lab

A personal lab for scaffolding and configuring a **self-hosted Octopus Server** entirely as code, with **Config-as-Code (CaC)** turned on so project state lives in Git rather than the Octopus database.

## Why this exists

- I wanted Terraform-driven setup of Octopus (envs, lifecycles, project groups, projects, Git credentials).
- I wanted CaC enabled from minute one — so the project's deployment process serialises out to OCL files in Git, not into the SQL database.
- This is intentionally a "prissy techy" setup. No customer is shipping their first Octopus install this way; the goal is to learn the IaC + CaC surface end-to-end against my own sandbox.

## Layout

```
octopus-iac-lab/
├── compose/     # docker-compose stack — the local Octopus Server (port 8090)
├── tofu/        # OpenTofu (.tf) that configures Octopus via its API
└── .octopus/    # OCL files Octopus reads/writes for the version-controlled project
```

Each folder has its own `README.md` describing what lives there. One `.env` at the root feeds all three.

## Target server

Local self-hosted Octopus, defined right here in [`compose/docker-compose.yml`](compose/docker-compose.yml):

- URL: `http://localhost:8090`
- Admin login: `admin` / `Password01!`
- Space: `Default` (Spaces-1)

## Bootstrap

1. Copy `.env.example` → `.env` and fill in `MASTER_KEY` (generate with `openssl rand -base64 16`).
2. Start the server: `make up`
3. Log in at <http://localhost:8090>, mint an API key (Profile → My API Keys), paste your `compose/license.xml` under Configuration → License.
4. Create a GitHub PAT with `repo` scope. Add `OCTOPUS_API_KEY`, `GITHUB_PAT`, and `CAC_REPO_URL` to `.env`.
5. From the repo root:
   ```bash
   make init      # one-time terraform init
   make plan      # see what Terraform wants to create
   make apply     # create envs, lifecycle, project group, Git credential, CaC project
   ```

After `apply`, opening the project in Octopus and editing the deployment process will write OCL to `.octopus/` in this repo. That's the point.

## Auth model — start simple

Starting with a **GitHub PAT** stored in `.env` for Octopus → GitHub access. Easy to wire, easy to rotate. If/when this stops feeling right, swap to a deploy key per repo.

## Not in scope

- No production guidance — this is a sandbox.
- No reference to the [`octopus-ttc`](../octopus-ttc/) demo. That project lives on its own; this lab exists to explore IaC + CaC patterns in isolation.
