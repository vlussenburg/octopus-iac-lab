# Octopus + Argo CD: pure gold and the black pill

Two takes on the same setup. One is the marketing-friendly version, one is what you mutter to yourself at 11pm three months in. Both are true.

## 🟡 The gold

### The combo is more than the sum

- **Octopus owns the *decision*.** "This release goes to prod for these tenants, now, with this approver." Lifecycles, envs, tenants, runbooks, manual gates, variable scoping — all natively modelled, no DIY.
- **Argo owns the *convergence*.** Cluster will reach the desired state and stay there. Drift gets reverted in a minute, no human in the loop.
- Decision and convergence are different problems. One tool is rarely best at both.

### What Octopus brings to Argo

- **Tenants as a first-class concept.** Argo has no native tenancy — you fake it with naming conventions or AppProjects. Octopus's tenant tags + per-tenant variables drive a 12-Application matrix from one project, no template explosion.
- **Lifecycles + env graphs.** Argo treats every Application as independent; "promote dev → prod" is a manual file move or a custom ApplicationSet. Octopus's progression is a graph the platform reasons about.
- **Approvals + manual intervention steps.** First-class. Argo equivalents are bolted on (Argo Workflows, OPA gates).
- **Runbooks** — the "maintenance mode on/off" pattern has no Argo equivalent. It's an out-of-band operation that fits Octopus's process model and would be painful to express in Argo.
- **Variable resolution.** Octopus resolves a value over (env × tenant × role × tag × machine) on every deploy. Helm + AppProjects can't do that without templating gymnastics.

### What Argo brings to Octopus

- **Continuous reconciliation.** Octopus deploys once and walks away. If someone `kubectl edit`s your Deployment, no one notices for weeks. Argo reverts within a sync interval.
- **Drift visibility.** The Argo UI shows live cluster vs git in seconds. Octopus's equivalent question ("is this still deployed correctly?") only gets answered on the next deploy.
- **Cluster bootstrap.** A fresh cluster pulls itself together from git via Argo + helm `extraObjects`. Octopus needs an agent installed from outside the cluster — chicken-and-egg.
- **Pull-based security.** Cluster reaches out; nothing inbound from CI to cluster. CI doesn't need cluster credentials. Compromised CI can't deploy to prod because CI doesn't deploy — it commits.

### The integration story is clean

- One Octopus deployment-process step (`Octopus.ArgoCDUpdateImageTags`) translates an Octopus release into a git commit Argo can reconcile. The boundary lives in two places: an annotation on each Argo App, and a single step in the project. Easy to reason about.
- The Gateway brings Argo state *back* into Octopus's UI. Operators who think in Octopus terms see Argo Apps under Infrastructure → Argo CD Instances. No context-switching cost for the people who already know Octopus.
- Two independent audit trails — Octopus deployment log AND git history — means post-incident reconstruction has redundancy. If Octopus's task log is unclear, the git diff isn't.

### It scales naturally

- **Lab / small team:** Octopus orchestrates, Argo deploys. Approvals + envs + runbooks in Octopus. Reconciliation + drift in Argo.
- **Big team / multi-cluster:** Argo ApplicationSets fan out per cluster; Octopus's tenant-tag-driven deploys decide which leaves get bumped. Each piece does what it's good at.
- **GitOps purist team:** Octopus is just the release-approval + image-tag-promotion gate. Two teams can split responsibility along a clean line.

---

## ⚫ The black pill

### Audit trail violates "single source of truth"

For one Argo-managed deploy you get:

- **Octopus log:** "User X clicked 'Deploy 1.1.18 to Production' at 10:42, approver was Y, snapshot was Z."
- **Git log:** "Octopus bot committed `image.tag: 1.1.18` to `gitops/.../values.yaml` at 10:42:03."
- **Argo sync history:** "Application synced from sha abc to sha def at 10:42:30, 12 resources affected."

One event, three sources, none complete. Reconciling them after an incident is a multi-tab exercise. "Single source of truth" only works inside one of the three boxes; spanning the system you're back to event correlation.

### Promotion semantics are doubled

- **Octopus's lifecycle:** Dev → Prod via release progression.
- **Argo's promotion:** edit `targetRevision`, copy values between branches, sync the next env.

When both are wired up: what does "promote to prod" *mean*? Whichever fires first wins. If a developer hand-edits values.yaml AND someone else triggers an Octopus prod deploy in parallel, the result depends on commit ordering. Race conditions in your delivery pipeline.

### Octopus doesn't actually speak GitOps

- The `ArgoCDUpdateImageTags` step is a single-purpose adapter. It bumps image tags. It can't:
  - Manage chart values beyond image references (no "scale replicas for all Apps in env X").
  - Coordinate sync waves across clusters.
  - Roll back via `git revert` — rolling back is another deploy that writes the *old* tag, so git history shows two commits for one logical rollback.
- Anything beyond "advance an image tag" needs custom scripting (run-script step → `git commit && git push`). At which point you're back to the GitOps maintenance you were trying to outsource.

### Failure modes multiply

- Octopus deploy succeeds → Argo sync fails. Octopus reports green; the fleet is red.
- `StepVerification.Method = ArgoCDApplicationHealthy` waits for Argo health, but if the health check passes prematurely (rolling update mid-flight, cached status), Octopus claims success while half the pods are still on the old image.
- Gateway connectivity has *three* layers of auth that can break independently: Octopus access token, ArgoCD JWT, gRPC TLS to Octopus. We hit each of them in this lab over a single afternoon.
- "Did it actually deploy?" now requires checking Octopus task log + Argo App status + `kubectl get pods`. Three tabs. Every time.

### Cognitive overhead

Two mental models, both deep:

- Octopus: lifecycles, envs, tenants, channels, library variable sets, scopes, runbooks, deployment process vs runbook process, OCL syntax, slug normalization.
- Argo: Applications, AppProjects, sources (directory / Helm / Kustomize / plugin), sync policy, automated.{prune,selfHeal}, syncOptions, ApplicationSets, AppProject restrictions.

A new team member learns *both* stacks. Two failure-mode catalogues to memorise. Two YAML dialects to write. Two sets of subtle quirks to step on (OCL's `environments` taking slugs not names; Argo's `directory.recurse: false` drift loop).

### Vendor lock-in concentration, not reduction

- The `argo.octopus.com/*` annotations and the `octopus-argocd-gateway` chart are Octopus-proprietary. Argo Apps with these annotations don't break without Octopus, but Octopus is now in the loop for image promotion.
- You can use Argo standalone. You can use Octopus standalone. Using both means committing to Octopus as the *senior* partner — Argo just executes.
- "Two tools, less lock-in" turned into "two tools, joined at the integration layer". To swap either out you re-architect both.

### The integration is one-way

- Gateway forwards Argo state → Octopus. Argo doesn't see Octopus state.
- If you only have Argo (engineers without Octopus access), you don't know what release is queued, what the lifecycle says, what's gated behind an approval.
- The "two views of the same truth" promise is half-true: Octopus can see Argo, Argo can't see Octopus.

### Sandbox cost is real

Octopus Server + SQL Server want ~6 GB of RAM together to be happy. Add Argo + 12 reconciliation loops + a Gateway pod streaming events back to Octopus, and Docker Desktop on a laptop tilts into thrashing under modest activity. We had to bump Docker Desktop to 16 GB and cap SQL Server explicitly to keep the cluster responsive. Production won't have this constraint, but the local-dev experience is heavier than either tool alone.

---

## TL;DR

The combo is genuinely better than either alone *for the right shape of team* — one that wants Octopus's release semantics AND Argo's convergence guarantees, has the operational maturity to run both, and the team-size to absorb two mental models. It's not a win on every dimension though: audit trails span three systems, promotion has two definitions, and you're now coupled to an Octopus-proprietary integration layer.

This lab demonstrates both patterns running side-by-side on purpose. The K8s agent path (push) and the Argo path (pull) deploy the same tenant matrix to the same cluster. Compare them yourself before betting on either.
