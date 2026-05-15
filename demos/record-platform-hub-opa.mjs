#!/usr/bin/env node
// Records a single-tab WebM of the platform-hub-opa demo (PR #46):
// Octopus deploys to a cluster guarded by a Gatekeeper Constraint
// that caps replicas by tenant tier (free=1, pro=2, enterprise=3).
//
// Sequence (Dev / acme-corp / tier=enterprise / cap=3):
//   1. Open Octopus deploy form. Set Replicas=5. Click Deploy.
//   2. Watch the task page — Gatekeeper denies admission, task fails,
//      the denial message lights up in the log.
//   3. Open a fresh deploy. Set Replicas=3. Click Deploy.
//   4. Task lands green.
//   5. Live app.
//
// Requires:
//   - kubectl context pointing at the lab cluster
//   - ConstraintTemplate + Constraint applied (gatekeeper-system)
//   - .env at repo root with OCTOPUS_API_KEY

import { chromium } from "../scripts/node_modules/playwright/index.mjs";
import fs from "node:fs";
import path from "node:path";
import { execSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "..");
const OUT = path.join(__dirname, "out");
fs.mkdirSync(OUT, { recursive: true });

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

const SPACE_ID = "Spaces-2";
const PROJECT_ID = "Projects-1";
const PROJECT_SLUG = "platform-hub-opa-randomquotes";
const ENV_ID = "Environments-1";
const TENANT_SLUG = "acme-corp";
const TIER_CAP = 3;
const BAD_REPLICAS = 5;
const NS = `randomquotes-local-${TENANT_SLUG}-dev`;
const APP_URL = `http://local-${TENANT_SLUG}-dev.localtest.me:8080/`;
const OCTOPUS_ADMIN_USER = process.env.OCTO_USER || "admin";
const OCTOPUS_ADMIN_PASS = process.env.OCTO_PASS || "Password01!";

const log = (...a) => console.log("[record-opa]", ...a);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function octoGet(p) {
  const r = await fetch(`${OCTO_URL}${p}`, { headers: { "X-Octopus-ApiKey": OCTO_KEY } });
  if (!r.ok) throw new Error(`octo GET ${p} → ${r.status}`);
  return r.json();
}

async function resolveRelease() {
  const releases = await octoGet(`/api/${SPACE_ID}/projects/${PROJECT_ID}/releases?take=10`);
  const semver = (releases.Items || []).filter((r) => /^\d+\.\d+\.\d+$/.test(r.Version));
  if (!semver.length) throw new Error("no semver releases on the project");
  const release = semver[0];
  log(`using release ${release.Version} (${release.Id})`);
  return { release };
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

async function cancelOtherQueued() {
  const r = await octoGet(`/api/tasks?states=Executing,Queued&take=30`);
  const others = (r.Items || []).filter((t) => /Deploy /.test(t.Description || ""));
  for (const t of others) {
    await fetch(`${OCTO_URL}/api/tasks/${t.Id}/cancel`, {
      method: "POST", headers: { "X-Octopus-ApiKey": OCTO_KEY },
    }).catch(() => {});
  }
  if (others.length) log(`cancelled ${others.length} sibling tasks`);
}

async function octoLogin(page) {
  await page.goto(`${OCTO_URL}/app#/users/sign-in`, { waitUntil: "domcontentloaded" });
  await sleep(1500);
  await page.fill('input[type="text"]', OCTOPUS_ADMIN_USER);
  await page.fill('input[type="password"]', OCTOPUS_ADMIN_PASS);
  await page.click('button[type="submit"]');
  await page.waitForURL(/dashboard|spaces|projects/i, { timeout: 15_000 });
  await sleep(1500);
}

async function dismissOctoChrome(page) {
  for (const sel of [
    'button[aria-label="Close help sidebar"]',
    'button[aria-label="Close"]',
    'aside[aria-label*="Help"] button',
  ]) {
    const b = page.locator(sel).first();
    if (await b.isVisible().catch(() => false)) {
      await b.click().catch(() => {});
      await sleep(300);
    }
  }
  await page.keyboard.press("Escape").catch(() => {});
}

async function banner(page, label, color = "#1a3a5c") {
  await page.evaluate(({ text, color }) => {
    let el = document.getElementById("__demo_banner");
    if (!el) {
      el = document.createElement("div");
      el.id = "__demo_banner";
      el.style.cssText = [
        "position:fixed", "top:0", "left:0", "right:0",
        "z-index:2147483647", "padding:14px 20px",
        `background:linear-gradient(90deg,#0f1f33,${color})`,
        "color:#fff",
        "font:600 18px -apple-system,BlinkMacSystemFont,Segoe UI,sans-serif",
        "letter-spacing:0.3px", "text-align:center",
        "box-shadow:0 2px 8px rgba(0,0,0,0.3)",
        "pointer-events:none",
      ].join(";");
      document.documentElement.appendChild(el);
    }
    el.textContent = text;
    el.style.background = `linear-gradient(90deg,#0f1f33,${color})`;
  }, { text: label, color });
}

// Open the deploy form (env+tenant pre-populated via URL query params),
// fill the prompted "Replica count" variable, click Deploy. Returns
// the deployment + task ids captured from the redirect.
async function submitDeployViaUI(page, release, replicas, tenantId) {
  const url =
    `${OCTO_URL}/app#/${SPACE_ID}/projects/${PROJECT_SLUG}` +
    `/deployments/releases/${release.Version}/deployments/create` +
    `?environmentIds=${ENV_ID}&tenantIds=${tenantId}`;
  log(`open deploy form (Replicas=${replicas})`);
  await page.goto(url, { waitUntil: "domcontentloaded" });
  await page.waitForTimeout(3000);
  await dismissOctoChrome(page);

  // Form ships with "Skip tenants where <version> is current on <env>"
  // checked. When the release we're deploying is already the live
  // version for our tenant (which it will be after the first run of
  // this demo), it filters every tenant out and keeps Deploy disabled.
  const skipBox = page.getByRole("checkbox", { name: /Skip tenants/i }).first();
  if (await skipBox.isChecked().catch(() => false)) {
    log("  uncheck Skip-already-deployed filter");
    await skipBox.uncheck();
    await page.waitForTimeout(800);
  }

  const deployBtn = page.locator('button[title="Deploy"]:not([disabled])').first();
  await deployBtn.waitFor({ state: "visible", timeout: 30_000 });

  log(`  fill Replicas = ${replicas}`);
  const replicasInput = page.getByLabel(/Replica count/i).first();
  await replicasInput.waitFor({ state: "visible", timeout: 15_000 });
  await replicasInput.fill(String(replicas));
  await page.waitForTimeout(800);

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
  const dep = await octoGet(`/api/${SPACE_ID}/deployments/${deploymentId}`);
  log(`UI deploy created ${deploymentId} → task ${dep.TaskId}`);
  return { deploymentId, taskId: dep.TaskId };
}

(async () => {
  if (!OCTO_KEY) throw new Error("OCTOPUS_API_KEY missing from .env");

  log("pre: resolve release + clear queue");
  const { release } = await resolveRelease();
  await cancelOtherQueued();
  const tenants = await octoGet(`/api/${SPACE_ID}/tenants?name=${TENANT_SLUG}`);
  const tenantId = tenants.Items[0].Id;

  const browser = await chromium.launch({ headless: false, slowMo: 200 });
  const VIEW = { width: 1680, height: 1000 };
  const ctx = await browser.newContext({
    viewport: VIEW,
    recordVideo: { dir: OUT, size: VIEW },
    ignoreHTTPSErrors: true,
  });
  const page = await ctx.newPage();

  try {
    log("scene 1: Octopus login");
    await octoLogin(page);

    log(`scene 2: deploy with Replicas=${BAD_REPLICAS} (above cap)`);
    await banner(
      page,
      `Operator attempts Replicas=${BAD_REPLICAS} for ${TENANT_SLUG} (tier=enterprise, cap=${TIER_CAP})`,
    );
    const bad = await submitDeployViaUI(page, release, BAD_REPLICAS, tenantId);
    const badTaskUrl =
      `${OCTO_URL}/app#/${SPACE_ID}/projects/${PROJECT_SLUG}` +
      `/deployments/releases/${release.Version}/deployments/${bad.deploymentId}`;

    log("scene 3: task fails — Gatekeeper admission denial");
    await page.goto(badTaskUrl, { waitUntil: "domcontentloaded" });
    await dismissOctoChrome(page);
    await banner(page, "Gatekeeper denies the manifest at admission", "#7a1f1f");
    await waitForTaskState(bad.taskId, ["Failed"], 180_000);
    // Open Task Log tab + scroll to the denial line so it's actually
    // readable on screen. Task Summary collapses the failure to a
    // generic "exit code 255".
    await page.reload({ waitUntil: "domcontentloaded" });
    await dismissOctoChrome(page);
    const logTab = page.getByRole("tab", { name: "Task Log" }).first();
    await logTab.waitFor({ state: "visible", timeout: 15_000 });
    await logTab.click();
    await page.waitForTimeout(2500);
    // Zoom the page so the denial text is actually readable at 1680px
    // record width — Octopus's log shows the kubectl JSON patch on
    // long wrapped lines and the policy message is just one of them.
    await page.evaluate(() => { document.body.style.zoom = "1.4"; });
    await page.waitForTimeout(500);

    // Scroll the denial line into view.
    const denialLine = page
      .getByText(/admission webhook "validation.gatekeeper.sh" denied/, { exact: false })
      .first();
    if (await denialLine.isVisible().catch(() => false)) {
      await denialLine.scrollIntoViewIfNeeded();
    } else {
      await page.evaluate(() => {
        const c = document.querySelector('[class*="taskLog"],[data-testid*="task-log"],main');
        if (c) c.scrollTop = c.scrollHeight;
      });
    }
    await page.waitForTimeout(800);
    await banner(
      page,
      `Task Failed — admission denied: tier=enterprise allows max ${TIER_CAP} replicas, got ${BAD_REPLICAS}`,
      "#7a1f1f",
    );
    await sleep(14_000);

    log(`scene 4: retry with Replicas=${TIER_CAP} (at cap)`);
    // Reset the zoom we applied in the failure scene before opening
    // the new deploy form — the form lays out poorly at 1.4x.
    await page.evaluate(() => { document.body.style.zoom = "1"; }).catch(() => {});
    await banner(page, `Operator retries with Replicas=${TIER_CAP} — matches tier cap`, "#1a5c3a");
    const good = await submitDeployViaUI(page, release, TIER_CAP, tenantId);
    const goodTaskUrl =
      `${OCTO_URL}/app#/${SPACE_ID}/projects/${PROJECT_SLUG}` +
      `/deployments/releases/${release.Version}/deployments/${good.deploymentId}`;

    log("scene 5: task succeeds");
    await page.goto(goodTaskUrl, { waitUntil: "domcontentloaded" });
    await dismissOctoChrome(page);
    await banner(page, "Within the cap — Gatekeeper admits", "#1a5c3a");
    await waitForTaskState(good.taskId, ["Success", "Failed"], 180_000);
    await page.reload({ waitUntil: "domcontentloaded" });
    await dismissOctoChrome(page);
    await banner(page, `Task Success — ${release.Version} with ${TIER_CAP} replicas`, "#1a5c3a");
    await sleep(10_000);

    log("scene 6: live app");
    await page.goto(`${APP_URL}?v=${release.Version}`, { waitUntil: "domcontentloaded" });
    await page.reload({ waitUntil: "domcontentloaded" });
    await banner(page, `Live app — ${PROJECT_SLUG} ${release.Version}`, "#1a5c3a");
    await sleep(8_000);

    log("done");
  } finally {
    await ctx.close();
    await browser.close();
  }

  const webms = fs.readdirSync(OUT)
    .filter((f) => f.endsWith(".webm"))
    .map((f) => ({ f, mtime: fs.statSync(path.join(OUT, f)).mtimeMs }))
    .sort((a, b) => b.mtime - a.mtime);
  if (!webms.length) { log("no WebM produced"); process.exit(1); }
  const src = path.join(OUT, webms[0].f);
  const dst = path.join(OUT, "platform-hub-opa.mp4");
  log(`ffmpeg: ${path.relative(REPO_ROOT, src)} → ${path.relative(REPO_ROOT, dst)}`);
  execSync(
    `ffmpeg -y -i "${src}" -c:v libx264 -pix_fmt yuv420p -crf 23 -preset fast "${dst}"`,
    { stdio: "inherit" },
  );
  const sizeMb = (fs.statSync(dst).size / 1024 / 1024).toFixed(2);
  log(`written: ${path.relative(REPO_ROOT, dst)} (${sizeMb} MiB)`);
})().catch((err) => {
  console.error("[record-opa] ERROR:", err.message);
  process.exit(1);
});
