#!/usr/bin/env node
// ServiceNow CR-gate demo recorder — single-tab WebM walking through the
// full deploy → CR → approval → resume flow against the running lab.
//
// Sequence:
//   0. (off-camera) trigger deploy: Dev (lifecycle precondition) →
//      Production, wait for Octopus to log the new CR number.
//   1. Octopus login (off-screen prelude).
//   2. Octopus task page — "Awaiting Change Request" with the CR
//      number visible.
//   3. ServiceNow CR detail page (CR in -5 / New, approval=requested).
//   4. Approve via REST (banner narrates the human action).
//   5. ServiceNow CR detail page reloaded (state=Implement, approval=
//      approved).
//   6. Back to the Octopus task page — gate cleared, deploy resumes,
//      task lands green.
//   7. Live app on Production-globex hostname.
//
// Prereqs (in repo root .env):
//   OCTOPUS_URL, OCTOPUS_API_KEY        — talk to local Octopus
//   SERVICENOW_URL, SERVICENOW_PASSWORD — login to PDI as admin
//
// Run from repo root:
//   node demos/record-snow.mjs
// Override admin login:
//   OCTO_USER=admin OCTO_PASS=Password01! node demos/record-snow.mjs
//
// Output → demos/out/snow.mp4

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  loadEnv, sleep, octoLogin, octoGet, octoPost,
  waitForTaskState, cancelSiblingDeploys, readLiveImageTag,
  launchRecorder, saveRecording, withPinnedScroll,
  banner, dismissOctoChrome,
} from "./recorder-lib.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "..");

// ---------- env ----------
const env = loadEnv();
// ServiceNow-specific env (not in lib).
function snowEnv() {
  const txt = fs.readFileSync(path.join(REPO_ROOT, ".env"), "utf8");
  const m = new Map();
  for (const line of txt.split("\n")) {
    const x = line.match(/^([A-Z_][A-Z0-9_]*)=(.*)$/);
    if (x) m.set(x[1], x[2]);
  }
  return m;
}
const E = snowEnv();
const SNOW_URL = (E.get("SERVICENOW_URL") || "").replace(/\/$/, "");
const SNOW_USER = "admin";
const SNOW_PASS = E.get("SERVICENOW_PASSWORD");

const SPACE_ID = "Spaces-2";
const PROJECT_SLUG = "servicenow-cr-gate-randomquotes";
const TENANT_SLUG = "globex";
// PROJECT_ID + DEV_ENV_ID + ENV_ID resolved at runtime from slug/name —
// Octopus rotates these on every `make nuke`, so hardcoding them rots
// quickly. Also, the prior hardcoded values had Dev/Prod swapped.
let PROJECT_ID;
let DEV_ENV_ID;
let ENV_ID;
// Production namespace + app URL — the snow demo flows through Production
// (Dev is the lifecycle precondition, off-camera).
const NS = `randomquotes-local-servicenow-cr-gate-${TENANT_SLUG}-production`;
const APP_URL = `http://local-servicenow-cr-gate-${TENANT_SLUG}-production.localtest.me:8080/`;

const log = (...a) => console.log("[record-snow]", ...a);

// ---------- semver compare (NOT in lib) ----------
function isNewer(a, b) {
  const p = (v) => v.split(/[^0-9]+/).filter(Boolean).map(Number);
  const xs = p(a), ys = p(b);
  for (let i = 0; i < Math.max(xs.length, ys.length); i++) {
    const x = xs[i] ?? 0, y = ys[i] ?? 0;
    if (y > x) return true;
    if (y < x) return false;
  }
  return false;
}

// ---------- release selection ----------
// Pick a release that's NOT the version currently running in
// Production for our tenant. Octopus's deploy form auto-skips
// tenants whose current Production version matches the release
// being deployed, so deploying the live version is a no-op. This
// is "next if exists, previous otherwise":
//   - Newest semver release with a version > live → roll forward.
//   - Else newest semver release with a version != live → roll
//     back (also fires a fresh CR, also exercises the gate).
async function resolveRelease() {
  const liveTag = readLiveImageTag(NS) || "0.0.0";
  log(`Production / ${TENANT_SLUG} currently running: ${liveTag}`);
  const releases = await octoGet(env, `/api/${SPACE_ID}/projects/${PROJECT_ID}/releases?take=10`);
  const semver = (releases.Items || []).filter((r) => /^\d+\.\d+\.\d+$/.test(r.Version));
  if (!semver.length) throw new Error("no semver releases on the project");
  const release =
    semver.find((r) => isNewer(liveTag, r.Version)) ||
    semver.find((r) => r.Version !== liveTag);
  if (!release) throw new Error(`no release differs from the current live tag ${liveTag}`);
  log(`using release ${release.Version} (${release.Id})`);
  return { release };
}

// Ensure the release has been successfully deployed to Dev for the
// target tenant. The lifecycle gates Production behind Dev success;
// the auto-trigger usually queues a Dev deploy when the release is
// created, but the recorder may need to deploy explicitly if the
// trigger fan-out was cancelled or the release pre-existed.
async function ensureDevDeployed(release) {
  // The Dev-phase precondition for Production is satisfied by *any* tenant
  // having a successful Dev deploy on this release — not specifically our
  // target tenant. globex is Production-only on this project (Dev isn't
  // even a connected env for it), so we seed Dev via acme-corp instead.
  const DEV_SEED_TENANT = "acme-corp";
  const tenants = await octoGet(env, `/api/${SPACE_ID}/tenants?name=${DEV_SEED_TENANT}`);
  const tenantId = tenants.Items[0].Id;
  const progression = await octoGet(env, `/api/${SPACE_ID}/releases/${release.Id}/progression`);
  const devPhase = (progression.Phases || []).find((p) => p.Name === "Dev") || progression.Phases[0];
  const devCell = (devPhase.Deployments || []).find((d) => d.EnvironmentId === DEV_ENV_ID);
  const successful = (devCell?.Deployments || []).find((d) =>
    d.State === "Success" && d.TenantId === tenantId,
  );
  if (successful) { log(`Dev already green for ${DEV_SEED_TENANT}`); return; }

  log(`Dev not green for ${DEV_SEED_TENANT} — submitting`);
  // Refresh the release's variable snapshot before deploying — old
  // releases captured their snapshot before later `tofu apply`s and may
  // otherwise fail with "No variable named 'Project.WorkerPool' was in scope".
  await octoPost(env, `/api/${SPACE_ID}/releases/${release.Id}/snapshot-variables`, {});
  const dep = await octoPost(env, `/api/${SPACE_ID}/deployments`, {
    ReleaseId: release.Id,
    EnvironmentId: DEV_ENV_ID,
    TenantId: tenantId,
    ProjectId: PROJECT_ID,
  });
  log(`Dev deployment ${dep.Id} → task ${dep.TaskId}`);
  await waitForTaskState(env, dep.TaskId, ["Success", "Failed"]);
  log("Dev deploy complete");
}

// Drive the Octopus UI to create a Production deployment of `release`
// for the target tenant. Two on-camera scenes:
//   - Show the deployments grid filtered to this release (so the
//     operator sees the current Dev/Prod state).
//   - Navigate to the pre-populated deploy form via the same deeplink
//     the grid's per-tenant "Deploy..." link uses (`environmentIds`
//     + `tenantIds`, both plural). Works whether or not the Production
//     cell already has an existing deployment — a redeploy lands on
//     the same form.
async function submitProductionDeployViaUI(page, release) {
  const tenants = await octoGet(env, `/api/${SPACE_ID}/tenants?name=${TENANT_SLUG}`);
  const tenantId = tenants.Items[0].Id;

  // Refresh the release's variable snapshot before the on-camera deploy —
  // old releases captured their snapshot before later `tofu apply`s and may
  // otherwise fail with "No variable named 'Project.WorkerPool' was in scope".
  await octoPost(env, `/api/${SPACE_ID}/releases/${release.Id}/snapshot-variables`, {});

  // Scene a: deployments grid filtered to this release. Kept brief —
  // the grid is just context; the click + gate are what matter.
  const gridUrl =
    `${env.OCTO_URL}/app#/${SPACE_ID}/projects/${PROJECT_SLUG}` +
    `/deployments?groupBy=None&page=1&pageSize=50&release=${release.Id}`;
  log(`opening deployments grid for ${release.Version}`);
  await page.goto(gridUrl, { waitUntil: "domcontentloaded" });
  await page.waitForTimeout(2500);
  await dismissOctoChrome(page);
  await banner(page, `Deployments grid — ready to push ${release.Version} to Production / ${TENANT_SLUG}`);
  await page.waitForTimeout(2000);

  // Scene b: pre-populated deploy form.
  const deployFormUrl =
    `${env.OCTO_URL}/app#/${SPACE_ID}/projects/${PROJECT_SLUG}` +
    `/deployments/releases/${release.Version}/deployments/create` +
    `?environmentIds=${ENV_ID}&tenantIds=${tenantId}`;
  log(`opening deploy form for Production / ${TENANT_SLUG}`);
  await page.goto(deployFormUrl, { waitUntil: "domcontentloaded" });
  // Wait for the Deploy button to become enabled — that's the signal
  // that env+tenant have loaded and the form is ready. Cheaper and
  // more reliable than a fixed sleep + networkidle.
  const deployBtn = page.locator('button[title="Deploy"]:not([disabled])').first();
  await deployBtn.waitFor({ state: "visible", timeout: 30_000 });
  await dismissOctoChrome(page);
  await banner(page, `Operator clicks Deploy — ${release.Version} → Production / ${TENANT_SLUG}`);
  await page.waitForTimeout(1500);

  log("  click Deploy");
  await deployBtn.click();

  let deploymentId;
  for (let i = 0; i < 30; i++) {
    await page.waitForTimeout(1500);
    const m = page.url().match(/\/deployments\/(Deployments-\d+)/);
    if (m) { deploymentId = m[1]; break; }
  }
  if (!deploymentId) throw new Error("did not land on deployment URL after Deploy click");
  const dep = await octoGet(env, `/api/${SPACE_ID}/deployments/${deploymentId}`);
  log(`UI deploy created ${deploymentId} → task ${dep.TaskId}`);
  return { deploymentId, taskId: dep.TaskId, version: release.Version };
}

// Poll the task until its log mentions "Change Number CHG…" — that's when
// Octopus has registered the CR and shown the "Awaiting change request"
// banner in the UI.
async function waitForCRBanner(taskId, timeoutMs = 90_000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const taskLog = await fetch(`${env.OCTO_URL}/api/tasks/${taskId}/raw`, {
      headers: { "X-Octopus-ApiKey": env.OCTO_KEY },
    }).then((r) => r.text());
    const m = taskLog.match(/Change Number \[?(CHG\d+)\]?/);
    if (m) return m[1];
    await sleep(3000);
  }
  throw new Error("timed out waiting for CR creation in task log");
}

// ---------- ServiceNow REST helpers ----------
async function snowAuthHeader() {
  return "Basic " + Buffer.from(`${SNOW_USER}:${SNOW_PASS}`).toString("base64");
}
async function lookupCR(crNumber) {
  const auth = await snowAuthHeader();
  const r = await fetch(`${SNOW_URL}/api/now/table/change_request?sysparm_query=number=${crNumber}^short_descriptionSTARTSWITHOctopus&sysparm_fields=sys_id,state,approval`, {
    headers: { Authorization: auth, Accept: "application/json" },
  }).then((r) => r.json());
  if (!r.result?.[0]) throw new Error(`CR ${crNumber} not found (Octopus-issued)`);
  return r.result[0];
}

// Toggle the PDI's "Change Model: Check State Transition" Business Rule. It
// rejects every REST PATCH of `state` field. Real ServiceNow customers
// don't run our PDI's stock change_model rules — they either replace them
// with a Standard Change Template (which has no state-transition guards)
// or run their own Flow. For demo automation, briefly disabling the rule
// is far cleaner than driving the SNow workflow UI.
const STATE_TRANSITION_BR_ID = "b6dae9e15317101034d1ddeeff7b1278";
async function setBusinessRule(active) {
  const auth = await snowAuthHeader();
  const r = await fetch(`${SNOW_URL}/api/now/table/sys_script/${STATE_TRANSITION_BR_ID}`, {
    method: "PATCH",
    headers: { Authorization: auth, "Content-Type": "application/json" },
    body: JSON.stringify({ active: active ? "true" : "false" }),
  });
  if (!r.ok) throw new Error(`toggle BR → ${r.status}`);
}

// Octopus's ITSM integration dedupes CRs by (project, release, env) —
// re-deploying a release reuses any prior CR. After the first demo run
// that CR is already in state=Implement, approval=approved, so the
// "pending → approve" arc never plays. Delete the existing one(s)
// pre-roll so Octopus mints a fresh CR on the next deploy click.
async function purgeExistingCRs(release) {
  const auth = await snowAuthHeader();
  const q = `short_descriptionSTARTSWITHOctopus^short_descriptionLIKEversion ${release.Version}^short_descriptionLIKETo "Production"`;
  const r = await fetch(
    `${SNOW_URL}/api/now/table/change_request?sysparm_query=${encodeURIComponent(q)}&sysparm_fields=sys_id,number`,
    { headers: { Authorization: auth } },
  ).then((r) => r.json());
  const items = r.result || [];
  if (!items.length) return;
  for (const cr of items) {
    const del = await fetch(`${SNOW_URL}/api/now/table/change_request/${cr.sys_id}`, {
      method: "DELETE",
      headers: { Authorization: auth },
    });
    log(`pre: deleted existing CR ${cr.number} (HTTP ${del.status})`);
  }
}

// The SNow demo is about the *Octopus gate*, not the SNow workflow —
// so we approve the CR via REST while the BR is toggled off (same
// trick capture-snow.mjs uses) and lean on the page reload to show
// the after-state in the SNow UI. Keeps the recording focused.
async function approveCRviaREST(crNumber) {
  const auth = await snowAuthHeader();
  const { sys_id: sysId } = await lookupCR(crNumber);
  log(`  approving ${crNumber} (${sysId}) via REST`);
  await setBusinessRule(false);
  try {
    for (const state of ["-4", "-3", "-2", "-1"]) {
      const r = await fetch(`${SNOW_URL}/api/now/table/change_request/${sysId}`, {
        method: "PATCH",
        headers: { Authorization: auth, "Content-Type": "application/json" },
        body: JSON.stringify({ state }),
      });
      if (!r.ok) throw new Error(`PATCH state=${state} → ${r.status}: ${(await r.text()).slice(0, 200)}`);
      await sleep(700);
    }
    const r = await fetch(`${SNOW_URL}/api/now/table/change_request/${sysId}`, {
      method: "PATCH",
      headers: { Authorization: auth, "Content-Type": "application/json" },
      body: JSON.stringify({ approval: "approved" }),
    });
    if (!r.ok) throw new Error(`PATCH approval=approved → ${r.status}`);
    log("  state=Implement, approval=approved");
  } finally {
    await setBusinessRule(true);
  }
}

// ---------- SNow Playwright login (SNow-specific, not in lib) ----------
async function snowLogin(page) {
  await page.goto(`${SNOW_URL}/login.do`, { waitUntil: "domcontentloaded" });
  await page.waitForTimeout(2000);
  await page.fill("#user_name", SNOW_USER);
  await page.fill("#user_password", SNOW_PASS);
  await page.click('button:has-text("Log in"), button[type="submit"], #sysverb_login');
  await page.waitForLoadState("networkidle", { timeout: 30_000 }).catch(() => {});
  await page.waitForTimeout(2500);
}

// ---------- main ----------
(async () => {
  if (!env.OCTO_KEY) throw new Error("OCTOPUS_API_KEY missing from .env");
  if (!SNOW_PASS) throw new Error("SERVICENOW_PASSWORD missing from .env");

  PROJECT_ID = (await octoGet(env, `/api/${SPACE_ID}/projects?partialName=${encodeURIComponent(PROJECT_SLUG)}`)).Items.find((p) => p.Slug === PROJECT_SLUG).Id;
  DEV_ENV_ID = (await octoGet(env, `/api/${SPACE_ID}/environments?partialName=Dev`)).Items.find((e) => e.Name === "Dev").Id;
  ENV_ID = (await octoGet(env, `/api/${SPACE_ID}/environments?partialName=Production`)).Items.find((e) => e.Name === "Production").Id;
  log(`resolved: project=${PROJECT_ID} dev=${DEV_ENV_ID} prod=${ENV_ID}`);

  // ----- Pre-recording (off-camera) -----
  // Find / build the next release, make sure Dev is green for our
  // tenant (lifecycle precondition for Production), and cancel the
  // trigger fan-out across the other projects. Production deploy is
  // saved for the recorded walkthrough — that's the button click the
  // viewer sees.
  log("pre: resolve release + ensure Dev success");
  const { release } = await resolveRelease();
  await cancelSiblingDeploys(env, null);
  await ensureDevDeployed(release);
  await cancelSiblingDeploys(env, null);
  await purgeExistingCRs(release);

  const { browser, ctx, page } = await launchRecorder({ slowMo: 200 });

  try {
    // ----- Scene 1: log into Octopus (off-screen prelude) -----
    log("scene 1: Octopus login");
    await octoLogin(page, env);

    // ----- Scene 2: Octopus deploy form — click Deploy to Production -----
    log("scene 2: click Deploy to Production");
    const { deploymentId, taskId, version } = await submitProductionDeployViaUI(page, release);
    const taskUrl = `${env.OCTO_URL}/app#/${SPACE_ID}/projects/${PROJECT_SLUG}/deployments/releases/${version}/deployments/${deploymentId}`;
    const crNumber = await waitForCRBanner(taskId);
    log(`CR created — ${crNumber}`);
    const lookup = await fetch(
      `${SNOW_URL}/api/now/table/change_request?sysparm_query=number=${crNumber}&sysparm_fields=sys_id`,
      { headers: { Authorization: await snowAuthHeader() } },
    ).then((r) => r.json());
    const crSysId = lookup.result[0].sys_id;
    const crUrl = `${SNOW_URL}/change_request.do?sys_id=${crSysId}`;

    // ----- Scene 3: Octopus task awaiting CR -----
    log("scene 3: Octopus task page awaiting CR");
    await page.goto(taskUrl, { waitUntil: "domcontentloaded" });
    await page.waitForSelector(`text=${crNumber}`, { timeout: 30_000 });
    await dismissOctoChrome(page);
    await banner(page, `Octopus deploy paused — awaiting ServiceNow ${crNumber} approval`);
    await sleep(12_000);

    // ----- Scene 4: ServiceNow login -----
    log("scene 4: ServiceNow login");
    await snowLogin(page);

    // ----- Scene 5: SNow CR pending -----
    log("scene 5: SNow CR pending");
    await page.goto(crUrl, { waitUntil: "domcontentloaded" });
    await sleep(5_000);
    await banner(page, `ServiceNow ${crNumber} — change request created by Octopus, awaiting approval`);
    await sleep(10_000);

    // ----- Scene 6: approve via REST (banner narrates) -----
    log("scene 6: approve CR");
    await banner(page, "Approver moves the CR through Assess → Authorize → Scheduled → Implement");
    await approveCRviaREST(crNumber);
    await sleep(3_000);

    // ----- Scene 7: SNow CR approved -----
    log("scene 7: SNow CR after approval");
    await page.reload({ waitUntil: "domcontentloaded" });
    await sleep(5_000);
    await banner(page, `${crNumber} approved — state=Implement, approval=approved`);
    await sleep(8_000);

    // ----- Scene 8: Octopus task resumes -----
    log("scene 8: Octopus task resumes");
    await page.goto(taskUrl, { waitUntil: "domcontentloaded" });
    await dismissOctoChrome(page);
    await banner(page, "Octopus picks up the approval — gate clears, deploy resumes");
    await withPinnedScroll(page, () => waitForTaskState(env, taskId, ["Success", "Failed"]));
    await page.reload({ waitUntil: "domcontentloaded" });
    await dismissOctoChrome(page);
    await banner(page, `Task green — release ${version} deployed to Production / ${TENANT_SLUG}`);
    await sleep(10_000);

    // ----- Scene 9: live app -----
    log("scene 9: live app on Production");
    await page.goto(`${APP_URL}?v=${version}`, { waitUntil: "domcontentloaded" });
    await page.reload({ waitUntil: "domcontentloaded" });
    await banner(page, `Live app — ${PROJECT_SLUG} ${version} serving on Production / ${TENANT_SLUG}`);
    await sleep(10_000);

    log("done");
  } finally {
    await saveRecording(page, "snow");
    await ctx.close();
    await browser.close();
  }
})().catch((err) => {
  console.error("[record-snow] ERROR:", err.message);
  process.exit(1);
});
