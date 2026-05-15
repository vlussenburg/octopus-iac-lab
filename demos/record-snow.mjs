#!/usr/bin/env node
// ServiceNow CR-gate demo recorder — single-tab WebM walking through the
// full deploy → CR → approval → resume flow against the running lab.
// Same orchestration as demos/capture-snow.mjs (which produces stills)
// but wraps the Playwright session in a recordVideo context and
// converts to MP4 for the demo/servicenow-cr-gate PR.
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
//   7. Live app on Production-initech hostname.
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

// Reuse the playwright install from scripts/ — no need for a second copy.
import { chromium } from "../scripts/node_modules/playwright/index.mjs";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "..");
const OUT = path.join(__dirname, "out");
fs.mkdirSync(OUT, { recursive: true });

// ---------- env reader ----------
function envMap() {
  const txt = fs.readFileSync(path.join(REPO_ROOT, ".env"), "utf8");
  const m = new Map();
  for (const line of txt.split("\n")) {
    const x = line.match(/^([A-Z_][A-Z0-9_]*)=(.*)$/);
    if (x) m.set(x[1], x[2]);
  }
  return m;
}
const E = envMap();
const OCTO_URL = E.get("OCTOPUS_URL") || "http://localhost:8090";
const OCTO_KEY = E.get("OCTOPUS_API_KEY");
const OCTO_USER = process.env.OCTO_USER || "admin";
const OCTO_PASS = process.env.OCTO_PASS || "Password01!";
const SNOW_URL = E.get("SERVICENOW_URL").replace(/\/$/, "");
const SNOW_USER = "admin";
const SNOW_PASS = E.get("SERVICENOW_PASSWORD");
const SPACE_ID = "Spaces-2";
const PROJECT_SLUG = "servicenow-cr-gate-randomquotes";
const PROJECT_ID = "Projects-4";
const DEV_ENV_ID = "Environments-1";
const ENV_ID = "Environments-2"; // Production — the change-controlled one
const TENANT_SLUG = "globex";
// Each capture run mints a fresh release so Octopus creates a NEW CR
// (CRs are keyed on release+env+tenant — reusing a release reuses the CR).
// Production namespace + app URL — the snow demo flows through Production
// (Dev is the lifecycle precondition, off-camera).
const NS = `randomquotes-local-servicenow-cr-gate-${TENANT_SLUG}-production`;

const log = (...a) => console.log("[record-snow]", ...a);
const APP_URL = `http://local-servicenow-cr-gate-${TENANT_SLUG}-production.localtest.me:8080/`;

// ---------- Octopus REST helpers ----------
async function octoGet(p) {
  const r = await fetch(`${OCTO_URL}${p}`, { headers: { "X-Octopus-ApiKey": OCTO_KEY } });
  if (!r.ok) throw new Error(`octo GET ${p} → ${r.status}`);
  return r.json();
}
async function octoPost(p, body) {
  const r = await fetch(`${OCTO_URL}${p}`, {
    method: "POST",
    headers: { "X-Octopus-ApiKey": OCTO_KEY, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!r.ok) throw new Error(`octo POST ${p} → ${r.status}: ${await r.text()}`);
  return r.json();
}

import { execSync } from "node:child_process";

// `latest-1` rather than `latest`. The newest release usually has its
// auto-trigger Dev deploys finishing or already mirrored across the
// Production cells (the trigger fan-out hits Dev for every tenant);
// picking one release back gives a reliably "Dev green, Production
// pending" cell to deploy from. That's the normal "next push" demo
// state, and the per-tenant `Deploy...` link in the grid only renders
// when Production is actually pending.
async function resolveRelease() {
  const releases = await octoGet(`/api/${SPACE_ID}/projects/${PROJECT_ID}/releases?take=10`);
  const semver = (releases.Items || []).filter((r) => /^\d+\.\d+\.\d+$/.test(r.Version));
  if (semver.length < 2) throw new Error("need at least two semver releases on the project");
  const release = semver[1];
  log(`using release ${release.Version} (${release.Id}) — second-latest`);
  return { release };
}

// Cancel sibling tasks the auto-trigger fans out across the other
// projects + tenants so MaxConcurrentTasks=2 doesn't bury our own.
async function cancelOtherQueued(keep = []) {
  const r = await octoGet(`/api/tasks?states=Executing,Queued&take=30`);
  const others = (r.Items || []).filter((t) => !keep.includes(t.Id) && /Deploy /.test(t.Description || ""));
  for (const t of others) {
    await fetch(`${OCTO_URL}/api/tasks/${t.Id}/cancel`, {
      method: "POST",
      headers: { "X-Octopus-ApiKey": OCTO_KEY },
    }).catch(() => {});
  }
  if (others.length) log(`cancelled ${others.length} sibling tasks`);
}

// Ensure the release has been successfully deployed to Dev for the
// target tenant. The lifecycle gates Production behind Dev success;
// the auto-trigger usually queues a Dev deploy when the release is
// created, but the recorder may need to deploy explicitly if the
// trigger fan-out was cancelled or the release pre-existed.
async function ensureDevDeployed(release) {
  const tenants = await octoGet(`/api/${SPACE_ID}/tenants?name=${TENANT_SLUG}`);
  const tenantId = tenants.Items[0].Id;
  const progression = await octoGet(`/api/${SPACE_ID}/releases/${release.Id}/progression`);
  const devPhase = (progression.Phases || []).find((p) => p.Name === "Dev") || progression.Phases[0];
  const devCell = (devPhase.Deployments || []).find((d) => d.EnvironmentId === DEV_ENV_ID);
  const successful = (devCell?.Deployments || []).find((d) =>
    d.State === "Success" && d.TenantId === tenantId,
  );
  if (successful) { log(`Dev already green for ${TENANT_SLUG}`); return; }

  log(`Dev not green for ${TENANT_SLUG} — submitting`);
  const dep = await octoPost(`/api/${SPACE_ID}/deployments`, {
    ReleaseId: release.Id,
    EnvironmentId: DEV_ENV_ID,
    TenantId: tenantId,
    ProjectId: PROJECT_ID,
  });
  log(`Dev deployment ${dep.Id} → task ${dep.TaskId}`);
  await waitForTaskState(dep.TaskId, ["Success", "Failed"]);
  log("Dev deploy complete");
}

// Drive the Octopus UI to create a Production deployment of `release`
// for the target tenant. The "right" entrypoint is the project's
// deployments grid (filtered to this release): every env × tenant cell
// has a per-cell "Deploy..." link that opens the deploy form fully
// pre-populated. From there it's one more click ("Deploy") to submit.
//
// The pre-populated form needs the URL params `environmentIds` and
// `tenantIds` (both plural) — Octopus's older snake_case singular form
// the recorder previously used is silently ignored.
async function submitProductionDeployViaUI(page, release) {
  const tenants = await octoGet(`/api/${SPACE_ID}/tenants?name=${TENANT_SLUG}`);
  const tenantId = tenants.Items[0].Id;

  const gridUrl =
    `${OCTO_URL}/app#/${SPACE_ID}/projects/${PROJECT_SLUG}` +
    `/deployments?groupBy=None&page=1&pageSize=50&release=${release.Id}`;
  log(`opening deployments grid for ${release.Version} (${release.Id})`);
  await page.goto(gridUrl, { waitUntil: "domcontentloaded" });
  await page.waitForLoadState("networkidle", { timeout: 30_000 }).catch(() => {});
  await page.waitForTimeout(4000);
  await page.screenshot({ path: path.join(OUT, "snow-grid.png") }).catch(() => {});
  await dismissOctoChrome(page);
  await banner(page, `Operator picks Production / ${TENANT_SLUG} for release ${release.Version}`);
  await page.waitForTimeout(2000);

  // The grid renders TWO "Deploy" anchors that match a href-based
  // filter for our env+tenant:
  //   - per-tenant: text="Deploy...",     title=""              ← we want this
  //   - env-wide:   text="Deploy all...", title="Deploy all..."  ← skip
  // The title attribute on the per-tenant link is empty in current
  // Octopus builds, so we filter by exact visible text instead.
  log(`  click Deploy… (Production / ${TENANT_SLUG})`);
  const deployLink = page.locator(
    `a[href*="environmentIds=${ENV_ID}"][href*="tenantIds=${tenantId}"]`,
  ).filter({ hasText: /^Deploy\.\.\.$/ }).first();
  await deployLink.waitFor({ state: "attached", timeout: 15_000 });
  await deployLink.scrollIntoViewIfNeeded();
  await deployLink.click();
  await page.waitForTimeout(4000);
  await dismissOctoChrome(page);

  log("  click Deploy");
  const deployBtn = page.locator('button[title="Deploy"]:not([disabled])').first();
  await deployBtn.waitFor({ state: "visible", timeout: 30_000 });
  await deployBtn.click();

  let deploymentId;
  for (let i = 0; i < 30; i++) {
    await page.waitForTimeout(1500);
    const m = page.url().match(/\/deployments\/(Deployments-\d+)/);
    if (m) { deploymentId = m[1]; break; }
  }
  if (!deploymentId) throw new Error("did not land on deployment URL after Deploy click");
  const dep = await octoGet(`/api/${SPACE_ID}/deployments/${deploymentId}`);
  log(`UI deploy created ${deploymentId} → task ${dep.TaskId}`);
  return { deploymentId, taskId: dep.TaskId, version: release.Version };
}

async function waitForCRBanner(taskId, timeoutMs = 90_000) {
  // Poll the task until its log mentions "Change Number CHG…" — that's when
  // Octopus has registered the CR and shown the "Awaiting change request"
  // banner in the UI.
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const log = await fetch(`${OCTO_URL}/api/tasks/${taskId}/raw`, {
      headers: { "X-Octopus-ApiKey": OCTO_KEY },
    }).then((r) => r.text());
    const m = log.match(/Change Number \[?(CHG\d+)\]?/);
    if (m) return m[1];
    await sleep(3000);
  }
  throw new Error("timed out waiting for CR creation in task log");
}

async function waitForTaskState(taskId, wantedStates, timeoutMs = 240_000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const t = await octoGet(`/api/tasks/${taskId}`);
    if (wantedStates.includes(t.State)) return t;
    await sleep(4000);
  }
  throw new Error(`timed out waiting for ${wantedStates.join("|")}`);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

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

// ---------- Playwright helpers ----------
async function octoLogin(page) {
  await page.goto(`${OCTO_URL}/app#/users/sign-in`, { waitUntil: "domcontentloaded" });
  await page.waitForTimeout(2000);
  await page.fill('input[type="text"]', OCTO_USER);
  await page.fill('input[type="password"]', OCTO_PASS);
  await page.click('button[type="submit"]');
  await page.waitForURL(/dashboard|spaces/i, { timeout: 15_000 });
  await page.waitForTimeout(2000);
}

async function dismissOctoChrome(page) {
  // Close the Help Sidebar if it's open — it covers the right third of the page.
  for (const sel of [
    'button[aria-label="Close help sidebar"]',
    'button[aria-label="Close"]',
    'aside[aria-label*="Help"] button',
    '[data-testid*="help"] button[aria-label*="lose"]',
  ]) {
    const b = page.locator(sel).first();
    if (await b.isVisible().catch(() => false)) {
      await b.click().catch(() => {});
      await page.waitForTimeout(400);
    }
  }
  // Cookie / "what's new" toasts
  await page.keyboard.press("Escape").catch(() => {});
}
async function snowLogin(page) {
  await page.goto(`${SNOW_URL}/login.do`, { waitUntil: "domcontentloaded" });
  await page.waitForTimeout(2000);
  await page.fill("#user_name", SNOW_USER);
  await page.fill("#user_password", SNOW_PASS);
  await page.click('button:has-text("Log in"), button[type="submit"], #sysverb_login');
  await page.waitForLoadState("networkidle", { timeout: 30_000 }).catch(() => {});
  await page.waitForTimeout(2500);
}
// Sticky banner — same shape as the bg-preview / blue-green recorders.
// Re-injected after each navigation so the audience always sees what
// scene they're in.
async function banner(page, label) {
  await page.evaluate((text) => {
    let el = document.getElementById("__demo_banner");
    if (!el) {
      el = document.createElement("div");
      el.id = "__demo_banner";
      el.style.cssText = [
        "position:fixed",
        "top:0",
        "left:0",
        "right:0",
        "z-index:2147483647",
        "padding:14px 20px",
        "background:linear-gradient(90deg,#0f1f33,#1a3a5c)",
        "color:#fff",
        "font:600 18px -apple-system,BlinkMacSystemFont,Segoe UI,sans-serif",
        "letter-spacing:0.3px",
        "text-align:center",
        "box-shadow:0 2px 8px rgba(0,0,0,0.3)",
        "pointer-events:none",
      ].join(";");
      document.documentElement.appendChild(el);
    }
    el.textContent = text;
  }, label);
}

// ---------- main ----------
(async () => {
  if (!OCTO_KEY) throw new Error("OCTOPUS_API_KEY missing from .env");
  if (!SNOW_PASS) throw new Error("SERVICENOW_PASSWORD missing from .env");

  // ----- Pre-recording (off-camera) -----
  // Find / build the next release, make sure Dev is green for our
  // tenant (lifecycle precondition for Production), and cancel the
  // trigger fan-out across the other projects. Production deploy is
  // saved for the recorded walkthrough — that's the button click the
  // viewer sees.
  log("pre: resolve release + ensure Dev success");
  const { release } = await resolveRelease();
  await cancelOtherQueued();
  await ensureDevDeployed(release);
  await cancelOtherQueued();

  const browser = await chromium.launch({ headless: false, slowMo: 200 });
  const VIEW = { width: 1680, height: 1000 };
  const ctx = await browser.newContext({
    viewport: VIEW,
    recordVideo: { dir: OUT, size: VIEW },
    ignoreHTTPSErrors: true,
  });
  const page = await ctx.newPage();

  try {
    // ----- Scene 1: log into Octopus (off-screen prelude) -----
    log("scene 1: Octopus login");
    await octoLogin(page);

    // ----- Scene 2: Octopus deploy form — click Deploy to Production -----
    log("scene 2: click Deploy to Production");
    const { deploymentId, taskId, version } = await submitProductionDeployViaUI(page, release);
    const taskUrl = `${OCTO_URL}/app#/${SPACE_ID}/projects/${PROJECT_SLUG}/deployments/releases/${version}/deployments/${deploymentId}`;
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
    await waitForTaskState(taskId, ["Success", "Failed"]);
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
    await ctx.close();
    await browser.close();
  }

  // ----- Post: convert WebM → MP4 -----
  const webms = fs.readdirSync(OUT)
    .filter((f) => f.endsWith(".webm"))
    .map((f) => ({ f, mtime: fs.statSync(path.join(OUT, f)).mtimeMs }))
    .sort((a, b) => b.mtime - a.mtime);
  if (!webms.length) { log("no WebM produced"); process.exit(1); }
  const src = path.join(OUT, webms[0].f);
  const dst = path.join(OUT, "snow.mp4");
  log(`ffmpeg: ${path.relative(REPO_ROOT, src)} → ${path.relative(REPO_ROOT, dst)}`);
  execSync(
    `ffmpeg -y -i "${src}" -c:v libx264 -pix_fmt yuv420p -crf 23 -preset fast "${dst}"`,
    { stdio: "inherit" },
  );
  const sizeMb = (fs.statSync(dst).size / 1024 / 1024).toFixed(2);
  log(`written: ${path.relative(REPO_ROOT, dst)} (${sizeMb} MiB)`);
})().catch((err) => {
  console.error("[record-snow] ERROR:", err.message);
  process.exit(1);
});
