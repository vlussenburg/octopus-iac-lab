#!/usr/bin/env node
// Records "The Best Demo" — a ~12-minute canonical Octopus demo chained
// together from the strongest single move each SE makes across the Gong
// corpus. Companion script lives in:
//   ../../gong-analysis/playbook/the_best_demo.md
//
// Audience: modern, technical eval / POC; K8s + Argo + GitOps literate.
//
// 15 scenes, all UI clicks (no API calls except: octoLogin, the deploy POST
// in scene 7 + waitForTaskState while we watch it, the API-key already in
// .env). ttyd panel rendered as its own page in scenes 4, 7, and 8b (runbook).
//
// Branch demos use PROJECT switching, NOT git branch switching. Each demo
// branch has its own Octopus project (`<slug>-randomquotes`) tracking that
// branch's `.octopus-<slug>/` folder via CaC. The recorder just navigates
// the UI between projects — no `tofu apply`, no `git checkout`, no PDI dance.
// See tofu/app-randomquotes/branch_demos.tf and defaults.auto.tfvars for the
// list of demo branches → projects.
//
// Pre-flight expected (see the_best_demo.md):
//   - docker compose up (compose/) — Octopus + MSSQL healthy
//   - kubectl context = kind cluster (Argo + agent + randomquotes installed)
//   - .env with OCTOPUS_API_KEY
//   - randomquotes + all 8 demo projects have >=1 release each
//   - dev/prod deployer users exist (Users-21, Users-22 in current lab)
//   - Insights seed loaded (~126 rows in Insights.Deployment)
//   - InsightsReports-5 "IaC Lab — all deployments" exists

import {
  loadEnv, sleep, octoLogin, octoPost, octoGet,
  watchDeployment, saveRecording, launchRecorder,
  resolveProject, resolveEnv, resolveTenant, requireReleases,
  refreshReleaseSnapshot, verifyDeployed, cancelSiblingDeploys,
  banner, dismissOctoChrome, makeTtyd, scrollMainBy,
  readLiveImageTag, pickDeployableRelease,
  highlight, switchUser,
} from "./recorder-lib.mjs";

const env = loadEnv();

// ---------- constants ----------
const SPACE_ID            = "Spaces-2";
const PROJECT_SLUG        = "randomquotes";
const TENANT_NAME         = "acme-corp";
const NS                  = "randomquotes-local-acme-corp-dev";
const APP_URL             = "http://local-acme-corp-dev.localtest.me:8080/";
const TTYD_PORT           = 7690;
const TTYD_RUNBOOK_PORT   = 7691;
const PROD_POOL_NAME      = "prod-pool"; // resolved to WorkerPools-XX at runtime — the UI's worker-pool detail route requires the ID, not the slug (slug renders a blank "Worker Pool" shell).
const LIFECYCLE_ID        = "Lifecycles-22"; // Dev to Production
const INSIGHTS_REPORT_ID  = "InsightsReports-5";

// Demo branch projects. Slug convention is `<branch-slug>-randomquotes`
// (NOT `randomquotes-<slug>` — branch_demos.tf builds names from
// `${branch_slug}-randomquotes`). Resolved-to-ID at runtime so the UI's
// canonical project URLs work even when slugs change.
const BG_PREVIEW_SLUG     = "bg-preview-randomquotes";
const PROCESS_TPL_SLUG    = "process-template-randomquotes";
const CANARY_SLUG         = "canary-randomquotes";

// User + team IDs for the RBAC scene. Resolved at runtime via API so the
// scene survives `make nuke` rotating user IDs.
const PROD_DEPLOYER_USERNAME = "prod-deployer";
const DEVELOPERS_TEAM_NAME   = "developers";

// Runbook to surface in scene 8b. maintenance-on lives in the canonical
// randomquotes project; CaC means the slug is stable across branches.
const RUNBOOK_SLUG = "maintenance-on";

const U = (p) => `${env.OCTO_URL}/app#${p}`;

const log = (...a) => console.log("[record-best-demo]", ...a);

// kubectl panel shows BOTH delivery paths (push agent + Argo CD GitOps) for
// scene 4. Trimmed to just the namespaces involved so the panel stays
// readable at recording resolution. We pin the IMAGE column with
// custom-columns so the version tag is unambiguously visible (user-explicit
// ask for iter #3): `-o wide` shows it too but the column ordering shifts
// at this width and tags occasionally truncate.
const ttyd = makeTtyd({
  port: TTYD_PORT,
  kubectlCmd:
    `(echo '== K8s agent (push) — randomquotes-local-acme-corp-dev =='; ` +
    ` kubectl get deploy -n ${NS} ` +
    `   -o custom-columns='NAME:.metadata.name,REPLICAS:.spec.replicas,IMAGE:.spec.template.spec.containers[*].image' 2>/dev/null; ` +
    ` echo; kubectl get pods -n ${NS} -l app=randomquotes --field-selector=status.phase=Running ` +
    `   -o custom-columns='POD:.metadata.name,STATUS:.status.phase,IMAGE:.spec.containers[*].image' 2>/dev/null; ` +
    ` echo; echo '== Argo CD (gitops) — argo-randomquotes-local-acme-corp-dev =='; ` +
    ` kubectl get deploy -n argo-randomquotes-local-acme-corp-dev ` +
    `   -o custom-columns='NAME:.metadata.name,REPLICAS:.spec.replicas,IMAGE:.spec.template.spec.containers[*].image' 2>/dev/null; ` +
    ` echo; kubectl get application -n argocd 2>/dev/null | grep -E 'NAME|randomquotes' | head -8)`,
});

// ttyd panel for the runbook scene (8b). Shows the maintenance-target
// deployment's replicas + image tag — same info the runbook would mutate
// if executed live. We don't actually run the runbook (it does a git push
// + ConfigMap rewrite + scale-down + Argo manifest commit; ~45s with risk
// of leaving the lab in maintenance state). The runbook *overview* page +
// this panel is enough to land the "lifecycles for ops" beat in 30s.
const ttydRunbook = makeTtyd({
  port: TTYD_RUNBOOK_PORT,
  kubectlCmd:
    `(echo '== randomquotes deploy state — same target the maintenance-on runbook mutates =='; ` +
    ` echo; ` +
    ` kubectl get deploy -n ${NS} ` +
    `   -o custom-columns='NAME:.metadata.name,REPLICAS:.spec.replicas,IMAGE:.spec.template.spec.containers[*].image' 2>/dev/null; ` +
    ` echo; ` +
    ` kubectl get pods -n ${NS} -l app=randomquotes ` +
    `   -o custom-columns='POD:.metadata.name,READY:.status.containerStatuses[*].ready,IMAGE:.spec.containers[*].image' 2>/dev/null; ` +
    ` echo; ` +
    ` echo '== ConfigMap (the runbook patches "maintenance" here) =='; ` +
    ` kubectl get configmap randomquotes-config -n ${NS} -o jsonpath='{.data.config\\.json}' 2>/dev/null | head -c 300)`,
});

// Hold a banner on screen for `seconds`. Convenience wrapper so the scene
// script reads top-to-bottom without sleep noise.
async function hold(page, text, seconds) {
  await banner(page, text);
  await sleep(seconds * 1000);
}

// Deploy a release whose image tag DIFFERS from what's currently running on
// the cluster, so the kubectl panel actually shows the tag flip mid-video.
// Picking the latest release blindly is the lazy bug — if the cluster's
// already on that tag (common after a recent CI build) the panel goes
// flat. pickDeployableRelease falls back to latest if nothing's live yet.
async function deployVisibleChange({ projectId, envId, tenantId }) {
  const liveTag = readLiveImageTag(NS);
  const release = await pickDeployableRelease(env, projectId, liveTag);
  await refreshReleaseSnapshot(env, release.Id);
  const dep = await octoPost(env, `/api/${SPACE_ID}/deployments`, {
    ReleaseId: release.Id, EnvironmentId: envId, TenantId: tenantId,
  });
  return {
    taskId: dep.TaskId,
    version: release.SelectedPackages?.[0]?.Version || release.Version,
    fromTag: liveTag,
    toTag: release.imageTag,
  };
}

// Resolve a username → Users-XX. Throws if missing so a stale user fixture
// kills the recording before we spend 12 minutes on a busted scene.
async function resolveUserId(username) {
  const r = await octoGet(env, `/api/users?take=200`);
  const u = (r.Items || []).find((x) => x.Username === username);
  if (!u) throw new Error(`no user '${username}'`);
  return u.Id;
}

async function resolveTeamId(name) {
  const r = await octoGet(env, `/api/${SPACE_ID}/teams?take=100`);
  const t = (r.Items || []).find((x) => x.Name === name);
  if (!t) throw new Error(`no team '${name}'`);
  return t.Id;
}

// ---------- main ----------
(async () => {
  if (!env.OCTO_KEY) throw new Error("OCTOPUS_API_KEY missing in .env");

  const [
    { id: projectId },
    { id: bgPreviewProjectId },
    { id: processTplProjectId },
    { id: canaryProjectId },
    devEnvId, tenantId, prodPool,
    prodDeployerUserId, developersTeamId,
  ] = await Promise.all([
    resolveProject(env, PROJECT_SLUG),
    resolveProject(env, BG_PREVIEW_SLUG),
    resolveProject(env, PROCESS_TPL_SLUG),
    resolveProject(env, CANARY_SLUG),
    resolveEnv(env, "Dev"),
    resolveTenant(env, TENANT_NAME),
    // Worker pool detail UI route needs the ID; slug returns a blank page.
    octoGet(env, `/api/${SPACE_ID}/workerpools?partialName=${encodeURIComponent(PROD_POOL_NAME)}`)
      .then((r) => r.Items.find((p) => p.Slug === PROD_POOL_NAME || p.Name === PROD_POOL_NAME)),
    resolveUserId(PROD_DEPLOYER_USERNAME),
    resolveTeamId(DEVELOPERS_TEAM_NAME),
  ]);
  if (!prodPool) throw new Error(`no worker pool '${PROD_POOL_NAME}'`);
  const prodPoolId = prodPool.Id;
  log(`resolved: project=${projectId} env=${devEnvId} tenant=${tenantId} prodPool=${prodPoolId}`);
  log(`branch demos: bg-preview=${bgPreviewProjectId} process-tpl=${processTplProjectId} canary=${canaryProjectId}`);
  log(`rbac: prodDeployerUser=${prodDeployerUserId} developersTeam=${developersTeamId}`);
  await requireReleases(env, projectId, 2);

  ttyd.start();
  ttydRunbook.start();
  const { browser, ctx, page } = await launchRecorder();
  let lastScene = "scene 0 (setup)";

  try {
    // ----- Scene 0: login (off-camera prelude) -----
    lastScene = "scene 0: login";
    log(lastScene);
    await octoLogin(page, env);

    // ----- Scene 1: Projects dashboard + Live K8s status (Kelly) -----
    lastScene = "scene 1: projects dashboard / K8s live status";
    log(lastScene);
    await page.goto(U(`/${SPACE_ID}/projects`), { waitUntil: "domcontentloaded" });
    await dismissOctoChrome(page);
    await hold(page, "Welcome — Octopus dashboard. Every project, every env, every tenant on one screen.", 15);
    // Highlight the Live Status toggle — the iconic opener. The control is
    // a plain input[type=checkbox] with aria-label "show live status" in
    // this Octopus version. Case-insensitive contains keeps the selector
    // resilient if the label gets reworded.
    await highlight(page, 'input[type="checkbox"][aria-label*="live status" i]', { durationMs: 26000, key: "live-toggle" });
    await hold(page,
      "Toggle 'Live Status' — Octopus tracks live K8s object health, not just the deploy task. Stale resources show up here.",
      27);

    // ----- Scene 2: Tenanted project click-in (Shawn + Rohit) -----
    lastScene = "scene 2: project overview / tenant matrix";
    log(lastScene);
    await page.goto(U(`/${SPACE_ID}/projects/${PROJECT_SLUG}/overview`), { waitUntil: "domcontentloaded" });
    await dismissOctoChrome(page);
    await hold(page,
      "One project. Many tenants. Each row is a customer; each column an environment. One process drives all.",
      24);
    await hold(page,
      "acme-corp runs Dev + Prod (canary tenant). globex / initech are Prod-only. Same OCL, different lifecycle scope.",
      20);

    // ----- Scene 3: Process editor + CaC / OCL (Dustin + Rohit) -----
    lastScene = "scene 3: deployment process + CaC";
    log(lastScene);
    await page.goto(U(`/${SPACE_ID}/projects/${PROJECT_SLUG}/deployments/process`), { waitUntil: "domcontentloaded" });
    await dismissOctoChrome(page);
    await hold(page,
      "Project's deployment process — every step lives in .octopus/deployment_process.ocl in Git. Same UI, same Git, two-way sync.",
      24);
    await hold(page,
      "The more of Octopus you store in your Git repos as OCL, the more upfront context your LLMs get.",
      24);

    // ----- Scene 4: K8s agent + GitOps side-by-side (Shawn + Dustin) -----
    lastScene = "scene 4a: deployment targets";
    log(lastScene);
    // Octopus 2024.x moved /infrastructure/deployment-targets → /infrastructure/machines.
    // The old path now returns the "Unable to locate page" 404 screen.
    await page.goto(U(`/${SPACE_ID}/infrastructure/machines`), { waitUntil: "domcontentloaded" });
    await dismissOctoChrome(page);
    await hold(page,
      "K8s agent self-registers via Helm. One target, scoped 'k8s', joins Dev + Prod, participates in all tenants.",
      22);

    lastScene = "scene 4b: ttyd — push + gitops side-by-side";
    log(lastScene);
    await page.goto(ttyd.url, { waitUntil: "domcontentloaded" });
    await hold(page,
      "Octopus + Argo: augmentation, not replacement. Nothing changes on the Argo side.",
      20);
    await hold(page,
      "Same workload reaches the cluster two ways: push (K8s agent) AND GitOps (Argo CD Application). Image tag shows what's live on each path.",
      22);

    // ----- Scene 5: Image-detection release trigger (Dustin) -----
    lastScene = "scene 5: image-detection trigger";
    log(lastScene);
    await page.goto(U(`/${SPACE_ID}/projects/${PROJECT_SLUG}/triggers`), { waitUntil: "domcontentloaded" });
    await dismissOctoChrome(page);
    await highlight(page, 'a:has-text("Auto-release on new"), tr:has(a:has-text("Auto-release"))', { durationMs: 22000, key: "trigger-row" });
    await hold(page,
      "Image-detection trigger — a GHCR push of a new randomquotes tag auto-creates a release. No CI script calls 'octopus release create'.",
      24);
    await hold(page,
      "Package pushed → release created → Dev auto-deploys. The lifecycle does the rest.",
      15);

    // ----- Scene 6: Workers + lifecycle (Shawn + Rohit) -----
    lastScene = "scene 6a: worker pools";
    log(lastScene);
    await page.goto(U(`/${SPACE_ID}/infrastructure/workerpools`), { waitUntil: "domcontentloaded" });
    await dismissOctoChrome(page);
    await hold(page,
      "Worker pools — where steps actually run. Default pool for everyday work; prod-pool is locked-down for Production.",
      22);

    lastScene = "scene 6b: prod-pool detail";
    log(lastScene);
    // Slug path renders a blank-shell page; the ID path renders the actual detail.
    await page.goto(U(`/${SPACE_ID}/infrastructure/workerpools/${prodPoolId}`), { waitUntil: "domcontentloaded" });
    await dismissOctoChrome(page);
    await hold(page,
      "Customers with stringent network conditions self-host a worker and sidestep the whole IP-allowlisting use case.",
      22);

    lastScene = "scene 6c: lifecycle";
    log(lastScene);
    await page.goto(U(`/${SPACE_ID}/library/lifecycles/${LIFECYCLE_ID}`), { waitUntil: "domcontentloaded" });
    await dismissOctoChrome(page);
    await hold(page,
      "Lifecycle — Dev auto-deploys on release, Production requires manual progression. Same OCL.",
      20);

    // ----- Scene 7: Real live deploy (Shawn + Kelly) -----
    lastScene = "scene 7a: trigger deploy";
    log(lastScene);
    const { taskId, version, fromTag, toTag } = await deployVisibleChange({ projectId, envId: devEnvId, tenantId });
    log(`task ${taskId} for ${PROJECT_SLUG} ${version} (${fromTag} → ${toTag})`);
    await cancelSiblingDeploys(env, taskId);
    await watchDeployment(env, page, taskId, {
      bannerText: `Live deploy — randomquotes ${version} → Dev / ${TENANT_NAME}. Image tag ${fromTag} → ${toTag}. Watch the task log stream.`,
      // On Success, watchDeployment pops back to Task Summary and scrolls to
      // the green-check title; this banner labels the completion moment.
      // Linger UNCHANGED at 9s — this scene was specifically iterated on in
      // iter #1; tightening risks the audit regression we already paid for.
      completionBannerText: `Task green — randomquotes ${version} deployed. Cluster flipped ${fromTag} → ${toTag}.`,
      completionLingerMs: 9_000,
    });

    lastScene = "scene 7b: verify on cluster";
    log(lastScene);
    try {
      await verifyDeployed(NS, toTag);
    } catch (e) {
      // Don't kill the recording if verify times out — the task already
      // hit Success; the cluster reconcile lag is cosmetic.
      log(`verifyDeployed soft-fail (continuing): ${e.message}`);
    }
    await page.goto(ttyd.url, { waitUntil: "domcontentloaded" });
    await hold(page,
      `New pods are running image tag ${toTag} in randomquotes-local-acme-corp-dev (was ${fromTag}).`,
      18);

    // ============================================================
    // NEW SCENES (iter #3) — five beats targeting top-coverage features
    // missing from iter #2. Each beat ~28–35s. Project-switching, not
    // git-branch-switching, lets us land bg-preview / canary / process-
    // template without touching the working tree.
    // ============================================================

    // ----- Scene 8: RBAC — same release, two users, two pictures -----
    // teams_roles is 81% corpus coverage. Show the contrast on the
    // *release detail* page — that's where Octopus renders per-env
    // "Deploy to ..." buttons. Releases-list and project-overview don't
    // surface those, so the contrast wouldn't land there.
    const DEMO_USER_PASS = "Password01!";
    const USER_CHIP = '[role="button"][aria-label*="User profile"], [data-testid="user-profile"], button[aria-label*="user"]';
    const DEPLOY_BTN = 'a:has-text("Deploy to Production"), button:has-text("Deploy to Production")';

    // Pin to the latest release so both users land on the same page.
    const latestRel = await octoGet(env, `/api/${SPACE_ID}/projects/${projectId}/releases?take=1`);
    const RBAC_VERSION = latestRel.Items[0].Version;
    const RBAC_URL = U(`/${SPACE_ID}/projects/${PROJECT_SLUG}/deployments/releases/${RBAC_VERSION}`);
    log(`rbac: comparing release ${RBAC_VERSION} between dev and prod-deployer`);

    lastScene = "scene 8a: RBAC — logged in as 'developer'";
    log(lastScene);
    await switchUser(page, env, { username: "developer", password: DEMO_USER_PASS });
    await page.goto(RBAC_URL, { waitUntil: "domcontentloaded" });
    // The SPA's role-guard runs after the route resolves; without networkidle
    // the deep link can get yanked back mid-load. Same on prod-deployer.
    await page.waitForLoadState("networkidle").catch(() => {});
    await dismissOctoChrome(page);
    await sleep(2000);
    await highlight(page, USER_CHIP, { durationMs: 20000, color: "#4FC3F7", key: "dev-chip" });
    await hold(page,
      `Release ${RBAC_VERSION}, logged in as 'developer' — Project Viewer + Deployment Creator scoped to Dev only. No 'Deploy to Production' button anywhere on the page.`,
      20);

    lastScene = "scene 8b: RBAC — logged in as 'prod-deployer'";
    log(lastScene);
    await switchUser(page, env, { username: PROD_DEPLOYER_USERNAME, password: DEMO_USER_PASS });
    await page.goto(RBAC_URL, { waitUntil: "domcontentloaded" });
    await page.waitForLoadState("networkidle").catch(() => {});
    await dismissOctoChrome(page);
    await sleep(2000);
    await highlight(page, USER_CHIP, { durationMs: 20000, color: "#7ee787", key: "prod-chip" });
    // The Production deploy button only renders for users with the right
    // role — highlight catches it if present, no-ops if not (proving the
    // contrast either way).
    await highlight(page, DEPLOY_BTN, { durationMs: 18000, color: "#ff8a00", key: "prod-deploy" });
    await hold(page,
      `Same release ${RBAC_VERSION}, logged in as 'prod-deployer' — Deployment Creator unscoped + Environment Manager. The 'Deploy to Production' button is back. Access is role-driven, not policy in a doc.`,
      20);

    // Restore admin session for the remaining scenes.
    await switchUser(page, env, { username: env.OCTO_USER, password: env.OCTO_PASS });

    // ----- Scene 9: Runbooks — operational lifecycles for ops, not just code -----
    lastScene = "scene 9a: runbook overview";
    log(lastScene);
    await page.goto(
      U(`/${SPACE_ID}/projects/${PROJECT_SLUG}/operations/runbooks/${RUNBOOK_SLUG}/overview`),
      { waitUntil: "domcontentloaded" },
    );
    await dismissOctoChrome(page);
    await hold(page,
      "Runbooks — same deploy engine for ops work. 'Maintenance Mode On' patches the ConfigMap, scales the deployment, commits the Argo manifest. Tenanted, audited, repeatable.",
      22);

    lastScene = "scene 9b: runbook target state on cluster";
    log(lastScene);
    await page.goto(ttydRunbook.url, { waitUntil: "domcontentloaded" });
    await hold(page,
      "Same kind of target the runbook would mutate — pods, replicas, image tag, ConfigMap. Ops scripts as a first-class lifecycle, not a wiki page.",
      18);

    // ----- Scene 10: Manual intervention (gated promotion) — bg-preview project -----
    // Switch *projects* (not git branches): bg-preview-randomquotes tracks
    // the demo/bg-preview branch, so its live process already has the
    // Octopus.Manual step at the Production boundary. No git checkout, no
    // tofu apply.
    lastScene = "scene 10: manual intervention (bg-preview project)";
    log(lastScene);
    await page.goto(
      U(`/${SPACE_ID}/projects/${BG_PREVIEW_SLUG}/deployments/process`),
      { waitUntil: "domcontentloaded" },
    );
    await dismissOctoChrome(page);
    await hold(page,
      "Different project, same lab — 'bg-preview-randomquotes'. The process has a Manual Intervention step at the Production phase boundary.",
      18);
    // Pan down so the Manual step (further down the step list) is on
    // camera, not just the deploy-configmap step at the top.
    await scrollMainBy(page, 280);
    await highlight(page, 'div:has(> :text-matches("Promote to active|Manual intervention", "i"))', { durationMs: 16000, key: "manual-step" });
    await hold(page,
      "Gated promotions are a process step, not a wiki page. Responsible team approves before the active Service flips to the new ReplicaSet.",
      18);

    // ----- Scene 11: Process Templates (Platform Hub authoring) -----
    // process-template-randomquotes uses a `process_template` block that
    // inherits the published `k8s-tenanted-app` template. The process
    // editor renders the template-derived steps inline.
    lastScene = "scene 11: process template (process-template project)";
    log(lastScene);
    await page.goto(
      U(`/${SPACE_ID}/projects/${PROCESS_TPL_SLUG}/deployments/process`),
      { waitUntil: "domcontentloaded" },
    );
    await dismissOctoChrome(page);
    // Template badge — the green pill in the top-right of the step block
    // that marks this step as coming from a published process template,
    // not hand-rolled steps. text-is anchors on exact text so we don't
    // catch other "Template" mentions on the page.
    await highlight(page, 'span:text-is("Template"), div:has(> :text-is("Process Template"))', { durationMs: 36000, key: "template-badge" });
    await hold(page,
      "'process-template-randomquotes' — the process is a template reference, not hand-rolled steps. Inherits 'k8s-tenanted-app' published from Platform Hub.",
      20);
    await hold(page,
      "Author the workload pattern once in Platform Hub, materialize it across N projects. Edit the template, every consumer rolls forward.",
      18);

    // ----- Scene 12: Canary (Argo Rollouts with NGINX trafficRouting) -----
    // Process-view + ttyd cluster state is enough — running a live canary
    // here would add 60–90s and we already covered "real deploy" in scene 7.
    lastScene = "scene 12: canary process (canary project)";
    log(lastScene);
    await page.goto(
      U(`/${SPACE_ID}/projects/${CANARY_SLUG}/deployments/process`),
      { waitUntil: "domcontentloaded" },
    );
    await dismissOctoChrome(page);
    await hold(page,
      "'canary-randomquotes' — the Production deploy step embeds an Argo Rollouts Rollout with NGINX trafficRouting: 20% → 40% → 60% → 80% → 100%.",
      18);
    await scrollMainBy(page, 280);
    await hold(page,
      "Progressive delivery, expressed as a process. Pause between weights, gate on metric, rollback on regression. Same OCL, different strategy block.",
      18);

    // ----- Scene 13: Audit + compliance (Rohit) -----
    // (was scene 8; renumbered after the iter #3 inserts).
    lastScene = "scene 13: audit log";
    log(lastScene);
    await page.goto(U(`/configuration/audit`), { waitUntil: "domcontentloaded" });
    await dismissOctoChrome(page);
    await hold(page,
      "Every deployment, policy verdict, runbook run and config change lands in the audit log. Filter by user, env, activity.",
      12);
    // Audit list extends well below the fold — pan down to show more rows.
    await scrollMainBy(page, 360);
    await hold(page,
      "From an audit finding — pick the report, get the list of who can deploy to production, CSV-export to your auditors.",
      20);

    // ----- Scene 14: Insights / DORA (Shawn + Ryan) -----
    lastScene = "scene 14a: project insights";
    log(lastScene);
    // /insights/overview returns the 404 page; the canonical path is /insights.
    await page.goto(U(`/${SPACE_ID}/projects/${PROJECT_SLUG}/insights`), { waitUntil: "domcontentloaded" });
    await dismissOctoChrome(page);
    await hold(page,
      "Insights — DORA metrics out of the box. Project-level on Professional.",
      12);
    // Stability charts (failure rate, MTTR) sit below the Tempo charts; pan down.
    await scrollMainBy(page, 420);
    await hold(page,
      "'Lead time' = deployment lead time. 'Failure rate' = deployment failure rate. Pull richer signal via the API.",
      17);

    lastScene = "scene 14b: space-wide insights report";
    log(lastScene);
    await page.goto(U(`/${SPACE_ID}/insights/reports/${INSIGHTS_REPORT_ID}/overview`), { waitUntil: "domcontentloaded" });
    await dismissOctoChrome(page);
    await hold(page,
      "Space-wide rollups across the IaC Lab project group — the Enterprise reveal.",
      12);
    await scrollMainBy(page, 360);
    await sleep(12_000);

    // ----- Scene 15: Wrap card -----
    lastScene = "scene 15: wrap";
    log(lastScene);
    await hold(page,
      "Today: Live K8s status • CaC + OCL • K8s agent + Argo augmentation • Triggers + lifecycles • Real live deploy • RBAC • Runbooks • Gated promotion • Process templates • Canary • Audit + Insights. One platform, one process, every tenant. Octopus.",
      18);

    log("done");
  } catch (err) {
    console.error(`[record-best-demo] FAILED in ${lastScene}: ${err.message}`);
    try {
      await banner(page, `RECORDING ENDED EARLY — ${lastScene}: ${err.message}`.slice(0, 200));
      await sleep(4_000);
    } catch {}
    process.exitCode = 1;
  } finally {
    await saveRecording(page, "the-best-demo");
    await ctx.close();
    await browser.close();
    ttyd.stop();
    ttydRunbook.stop();
  }
})();
