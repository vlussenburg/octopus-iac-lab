#!/usr/bin/env node
// ServiceNow CR-gate demo capture — orchestrates a full deploy → CR →
// approval → resume flow against the running lab and saves screenshots
// for the demo/servicenow-cr-gate PR description.
//
// Prereqs (in repo root .env):
//   OCTOPUS_URL, OCTOPUS_API_KEY        — talk to local Octopus
//   SERVICENOW_URL, SERVICENOW_PASSWORD — login to PDI as admin
//
// Run from repo root:
//   node demos/capture-snow.mjs
// Override admin login:
//   OCTO_USER=admin OCTO_PASS=Password01! node demos/capture-snow.mjs
//
// Output → demos/out/snow-NN-*.png

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
const PROJECT_ID = "Projects-6";
const DEV_ENV_ID = "Environments-1";
const ENV_ID = "Environments-2"; // Production — the change-controlled one
const TENANT_SLUG = "initech";
// Each capture run mints a fresh release so Octopus creates a NEW CR
// (CRs are keyed on release+env+tenant — reusing a release reuses the CR).
const DEMO_VERSION = `1.99.${Math.floor(Date.now() / 1000) % 100000}-snow`;

const log = (...a) => console.log("[snow-demo]", ...a);

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

async function triggerDeploy() {
  // Use the `octopus` CLI — it auto-resolves package versions from feeds and
  // handles the CaC GitRef requirement, which the raw API doesn't.
  log(`creating release ${DEMO_VERSION} via octopus CLI`);
  const env = {
    ...process.env,
    OCTOPUS_HOST: OCTO_URL,
    OCTOPUS_API_KEY: OCTO_KEY,
    OCTOPUS_SPACE: "IaC Sandbox",
  };
  execSync(
    `octopus release create --project ${PROJECT_SLUG} --version ${DEMO_VERSION} --git-ref refs/heads/demo/servicenow-cr-gate --no-prompt`,
    { env, stdio: ["ignore", "ignore", "inherit"] },
  );
  log(`release created`);

  // Find the new release Id
  const releases = await octoGet(`/api/${SPACE_ID}/projects/${PROJECT_ID}/releases?searchByVersion=${encodeURIComponent(DEMO_VERSION)}`);
  const release = releases.Items.find((r) => r.Version === DEMO_VERSION);
  if (!release) throw new Error(`release ${DEMO_VERSION} not found after create`);

  const tenants = await octoGet(`/api/${SPACE_ID}/tenants?name=${TENANT_SLUG}`);
  const tenantId = tenants.Items[0].Id;

  // Lifecycle forces Dev → Production. Run Dev first, wait for success,
  // then deploy to Production — that's where the gate actually fires.
  log("deploying to Dev (lifecycle precondition)");
  const devDeploy = await octoPost(`/api/${SPACE_ID}/deployments`, {
    ReleaseId: release.Id,
    EnvironmentId: DEV_ENV_ID,
    TenantId: tenantId,
    ProjectId: PROJECT_ID,
  });
  await waitForTaskState(devDeploy.TaskId, ["Success", "Failed"]);
  log(`Dev deploy complete (${devDeploy.TaskId})`);

  log("deploying to Production");
  const deployment = await octoPost(`/api/${SPACE_ID}/deployments`, {
    ReleaseId: release.Id,
    EnvironmentId: ENV_ID,
    TenantId: tenantId,
    ProjectId: PROJECT_ID,
  });
  log(`deployment ${deployment.Id} → task ${deployment.TaskId}`);
  return { releaseId: release.Id, version: release.Version, taskId: deployment.TaskId, deploymentId: deployment.Id };
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

async function approveCRviaREST(crNumber) {
  const auth = await snowAuthHeader();
  const { sys_id: sysId } = await lookupCR(crNumber);
  log(`approving CR ${crNumber} (${sysId})`);

  await setBusinessRule(false);
  try {
    // Walk Normal Change state: -5 New → -4 Assess → -3 Authorize → -2
    // Scheduled → -1 Implement. State-change workflows set approval to
    // "requested" along the way, so we finalise with approval=approved.
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
async function shot(page, slug, waitMs = 1500) {
  await page.waitForTimeout(waitMs);
  const file = path.join(OUT, `snow-${slug}.png`);
  await page.screenshot({ path: file, fullPage: false });
  log(`shot → ${path.relative(REPO_ROOT, file)}`);
}

// ---------- main ----------
(async () => {
  if (!OCTO_KEY) throw new Error("OCTOPUS_API_KEY missing from .env");
  if (!SNOW_PASS) throw new Error("SERVICENOW_PASSWORD missing from .env");

  log("=== 1. Trigger a fresh deploy ===");
  const { taskId, deploymentId, version } = await triggerDeploy();

  log("=== 2. Wait for CR creation ===");
  const crNumber = await waitForCRBanner(taskId);
  log(`CR created: ${crNumber}`);

  const browser = await chromium.launch();
  const ctx = await browser.newContext({
    viewport: { width: 1440, height: 1000 },
    ignoreHTTPSErrors: true,
  });
  const page = await ctx.newPage();

  try {
    log("=== 3. Octopus: awaiting-CR banner ===");
    await octoLogin(page);
    await page.goto(`${OCTO_URL}/app#/${SPACE_ID}/projects/${PROJECT_SLUG}/deployments/releases/${version}/deployments/${deploymentId}`, {
      waitUntil: "domcontentloaded",
    });
    await page.waitForSelector(`text=${crNumber}`, { timeout: 30_000 });
    await dismissOctoChrome(page);
    await shot(page, "01-octopus-awaiting-cr", 2500);

    log("=== 4. ServiceNow: CR before approval ===");
    const snowPage = await ctx.newPage();
    await snowLogin(snowPage);
    // Navigate to the CR
    const lookup = await fetch(`${SNOW_URL}/api/now/table/change_request?sysparm_query=number=${crNumber}&sysparm_fields=sys_id`, {
      headers: { Authorization: await snowAuthHeader() },
    }).then((r) => r.json());
    const sysId = lookup.result[0].sys_id;
    await snowPage.goto(`${SNOW_URL}/nav_to.do?uri=change_request.do?sys_id=${sysId}`, { waitUntil: "domcontentloaded" });
    await snowPage.waitForTimeout(5000);
    await shot(snowPage, "02-servicenow-cr-pending", 1500);

    log("=== 5. Approve CR via REST (BR-disable trick) ===");
    await approveCRviaREST(crNumber);

    log("=== 6. ServiceNow: CR after approval ===");
    await snowPage.reload({ waitUntil: "domcontentloaded" });
    await snowPage.waitForTimeout(4000);
    await shot(snowPage, "03-servicenow-cr-approved", 1500);

    log("=== 7. Wait for Octopus deploy to resume + succeed ===");
    await waitForTaskState(taskId, ["Success", "Failed"]);

    log("=== 8. Octopus: deploy succeeded ===");
    await page.reload({ waitUntil: "domcontentloaded" });
    await page.waitForTimeout(4500);
    await dismissOctoChrome(page);
    await shot(page, "04-octopus-deploy-success", 1500);

    log("=== All screenshots in demos/out/ ===");
  } finally {
    await browser.close();
  }
})().catch((err) => {
  console.error("[snow-demo] ERROR:", err.message);
  process.exit(1);
});
