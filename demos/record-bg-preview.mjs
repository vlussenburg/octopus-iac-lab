#!/usr/bin/env node
// Records a single-tab WebM of the bg-preview demo (PR #30).
//
// Same Argo Rollouts shape as blue-green, but autoPromotionEnabled=false
// AND the promote is now gated inside Octopus: the deployment process
// has a Manual Intervention step ("Promote to active?") between
// `Deploy Manifests` and a `Promote Rollout` script step that shells
// `kubectl argo rollouts promote`. So the gate is visible in the
// Octopus task page itself.
//
// Sequence:
//   0. (off-camera) baseline: if a rollout is currently paused from a
//      prior demo, promote + wait for drain so we start clean.
//   1. kubectl 'before' — single live RS, both Services on it.
//   2. Create a fresh release on demo/bg-preview branch (the new OCL
//      isn't on prior releases). Deploy it, follow Octopus task page
//      until it lands in the manual-intervention pause.
//   3. kubectl 'paused' — preview Service targets new RS, active still
//      on the old one.
//   4. Preview hostname — new version behind the gate.
//   5. Active hostname — still old version.
//   6. Back to Octopus task page (banner: "approver clicks Proceed"),
//      submit the interruption via API. Octopus runs Promote Rollout
//      which shells `kubectl argo rollouts promote` and blocks on
//      `rollouts status` until the drain completes. Task → Success.
//   7. kubectl 'drained' — single live RS again.
//   8. Active hostname (cache-busted) — now serving new version.
//
// Requires:
//   - ffmpeg + kubectl on PATH (kubectl-argo-rollouts is installed
//     inside the Octopus K8s agent step now, not needed locally)
//   - kubectl context pointing at the lab cluster
//   - .env at repo root with OCTOPUS_API_KEY

import { chromium } from "../scripts/node_modules/playwright/index.mjs";
import fs from "node:fs";
import path from "node:path";
import { spawn, execSync, exec } from "node:child_process";
import { fileURLToPath } from "node:url";
import http from "node:http";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "..");
const OUT = path.join(__dirname, "out");
fs.mkdirSync(OUT, { recursive: true });

// ---------- env ----------
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

// ---------- demo constants ----------
const PROJECT_SLUG = "bg-preview-randomquotes";
const PROJECT_ID = "Projects-5";
const SPACE_ID = "Spaces-2";
const DEV_ENV_ID = "Environments-1";
const TENANT_NAME = "acme-corp";
const NS = "randomquotes-local-bg-preview-acme-corp-dev";
const APP_URL = "http://local-bg-preview-acme-corp-dev.localtest.me:8080/";
const PREVIEW_URL = "http://bg-local-bg-preview-acme-corp-dev.localtest.me:8080/";
const ROLLOUT_NAME = "randomquotes";
const TTYD_PORT = 7683; // distinct from blue-green's port so both can run side-by-side
const TTYD_URL = `http://localhost:${TTYD_PORT}/`;
const OCTOPUS_ADMIN_USER = process.env.OCTO_USER || "admin";
const OCTOPUS_ADMIN_PASS = process.env.OCTO_PASS || "Password01!";

const log = (...a) => console.log("[record-bgp]", ...a);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------- kubectl panel lifecycle ----------
//
// We used to embed `ttyd` here, but xterm.js in headed Chromium rendered the
// grid stuck to the bottom of the viewport (layout calc differed from headless
// in ways we couldn't beat with CSS). Instead, serve a self-polling HTML page
// from a tiny Node http server: `/` returns the shell, `/kubectl` runs the
// command and returns plain text, the page renders it in a `<pre>` that we
// fully control. Same demo intent, predictable layout.
function ensureTtyd() {
  const html = `<!doctype html>
<html><head><meta charset="utf-8"><title>cluster</title>
<style>
  /* 14px is the sweet spot at 1680px wide: kubectl get -o wide fits the
     full SELECTOR column on one line without horizontal clipping, and the
     text is still readable in the rendered video. */
  html,body { margin:0; padding:0; height:100vh; width:100vw; background:#0b0f17; color:#e6edf3; font:600 14px/1.3 "MesloLGS NF",Menlo,Consolas,monospace; overflow:hidden; }
  body { padding:72px 28px 28px 28px; box-sizing:border-box; }
  #time { position:fixed; top:60px; right:20px; font-size:14px; color:#7d8590; z-index:1; }
  pre { margin:0; white-space:pre; font-variant-ligatures:none; tab-size:2; }
</style></head>
<body>
<div id="time"></div>
<pre id="out">loading…</pre>
<script>
  async function tick() {
    try {
      const r = await fetch('/kubectl', { cache:'no-store' });
      const t = await r.text();
      document.getElementById('out').textContent = t;
      document.getElementById('time').textContent = new Date().toLocaleTimeString();
    } catch (e) { /* ignore transient */ }
  }
  tick(); setInterval(tick, 2000);
</script>
</body></html>`;

  const server = http.createServer((req, res) => {
    if (req.url === "/" || req.url === "/index.html") {
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      res.end(html);
      return;
    }
    if (req.url === "/kubectl") {
      // Include svc so the audience can read the active Service's
      // SELECTOR (rollouts-pod-template-hash=<hash>) and visually match
      // it against the ReplicaSet hashes — that's where the blue-green
      // switchover actually happens.
      exec(
        `kubectl get rollouts.argoproj.io,replicaset,svc,pods -n ${NS} -o wide 2>/dev/null`,
        { maxBuffer: 1024 * 1024 },
        (err, stdout) => {
          res.writeHead(200, { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store" });
          res.end(stdout || "(no resources yet)");
        },
      );
      return;
    }
    res.writeHead(404); res.end();
  });
  server.listen(TTYD_PORT);
  log(`kubectl panel listening on :${TTYD_PORT}`);
  return server;
}

// ---------- Octopus REST helpers ----------
async function octoPost(p, body) {
  const r = await fetch(`${OCTO_URL}${p}`, {
    method: "POST",
    headers: { "X-Octopus-ApiKey": OCTO_KEY, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!r.ok) throw new Error(`octo POST ${p} → ${r.status}: ${await r.text()}`);
  return r.json();
}
async function octoGet(p) {
  const r = await fetch(`${OCTO_URL}${p}`, { headers: { "X-Octopus-ApiKey": OCTO_KEY } });
  if (!r.ok) throw new Error(`octo GET ${p} → ${r.status}`);
  return r.json();
}

// "Previous" version = whatever tag the current live pod is running.
function currentLiveTag() {
  try {
    const img = execSync(
      `kubectl get pods -n ${NS} -l app=randomquotes ` +
      `-o jsonpath='{.items[0].spec.containers[0].image}'`,
      { encoding: "utf8" },
    ).trim();
    return img.split(":").pop() || "";
  } catch {
    return "";
  }
}

// SemVer-ish "is b strictly newer than a" for the lab's 1.1.N image tag
// scheme. Falls back to string compare for non-numeric prefixes.
function isNewer(a, b) {
  const parse = (v) => v.split(/[^0-9]+/).filter(Boolean).map(Number);
  const xs = parse(a), ys = parse(b);
  for (let i = 0; i < Math.max(xs.length, ys.length); i++) {
    const x = xs[i] ?? 0, y = ys[i] ?? 0;
    if (y > x) return true;
    if (y < x) return false;
  }
  return b > a; // tiebreak on full string
}

// Pick the newest existing release on the project that's strictly
// newer than `previousTag`. Returns null if nothing qualifies.
async function findNewerRelease(previousTag) {
  const releases = await octoGet(`/api/${SPACE_ID}/projects/${PROJECT_ID}/releases?take=10`);
  return (releases.Items || []).find((r) => isNewer(previousTag, r.Version)) || null;
}

// Kick the CI build workflow and block until Octopus's image-detection
// trigger materialises a release with a version > `previousTag`. This
// is the lab's normal CI→trigger path; the recorder just orchestrates
// it so demo runs always have a real, trustworthy version delta.
async function buildAndWaitForRelease(previousTag, timeoutMs = 8 * 60_000) {
  const PAT = (await new Promise((resolve) => {
    const txt = fs.readFileSync(path.join(REPO_ROOT, ".env"), "utf8");
    const m = txt.match(/^GITHUB_PAT=(.+)$/m);
    resolve(m ? m[1] : null);
  }));
  if (!PAT) throw new Error("GITHUB_PAT missing from .env — needed to dispatch CI build");

  log("dispatching build.yml workflow_dispatch on main");
  const dispatch = await fetch(
    "https://api.github.com/repos/vlussenburg/octopus-iac-lab/actions/workflows/build.yml/dispatches",
    {
      method: "POST",
      headers: { Authorization: `Bearer ${PAT}`, Accept: "application/vnd.github+json" },
      body: JSON.stringify({ ref: "main" }),
    },
  );
  if (!dispatch.ok) throw new Error(`build dispatch → ${dispatch.status}: ${await dispatch.text()}`);

  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const r = await findNewerRelease(previousTag);
    if (r) {
      log(`new release ${r.Version} landed in Octopus`);
      return r;
    }
    await sleep(10_000);
  }
  throw new Error(`timed out waiting for a release newer than ${previousTag}`);
}

// Resolves the previous + next versions before the cameras roll. If no
// new release exists, kicks the CI build and waits — that can take a
// few minutes and the recorder mustn't be filming during it.
async function resolveRelease() {
  const previousVersion = currentLiveTag();
  if (!previousVersion) throw new Error("could not read current live pod image tag");
  log(`previous (live) version: ${previousVersion}`);
  let release = await findNewerRelease(previousVersion);
  if (!release) {
    log(`no release newer than ${previousVersion} — triggering build`);
    release = await buildAndWaitForRelease(previousVersion);
  }
  log(`next version: ${release.Version} (release ${release.Id})`);
  return { previousVersion, release };
}

async function submitDeploy(release) {
  const tenants = await octoGet(`/api/${SPACE_ID}/tenants?name=${TENANT_NAME}`);
  const tenantId = tenants.Items[0].Id;
  const dep = await octoPost(`/api/${SPACE_ID}/deployments`, {
    ReleaseId: release.Id,
    EnvironmentId: DEV_ENV_ID,
    TenantId: tenantId,
    ProjectId: PROJECT_ID,
  });
  log(`deployment ${dep.Id} → task ${dep.TaskId}`);
  return { taskId: dep.TaskId, version: release.Version };
}

// The CI build + auto-release trigger fans out 18 deploys (6 projects ×
// 3 tenants) to Dev each time. Cancel everything that isn't ours so
// MaxConcurrentTasks=2 doesn't bury our task behind 17 others.
async function cancelOtherQueued(myTaskId) {
  const r = await octoGet(`/api/tasks?states=Executing,Queued&take=30`);
  const others = (r.Items || []).filter((t) => t.Id !== myTaskId && /Deploy /.test(t.Description || ""));
  for (const t of others) {
    try {
      await fetch(`${OCTO_URL}/api/tasks/${t.Id}/cancel`, {
        method: "POST",
        headers: { "X-Octopus-ApiKey": OCTO_KEY },
      });
    } catch {}
  }
  if (others.length) log(`cancelled ${others.length} sibling tasks fanning out from the build trigger`);
}

// Poll the cluster until the only ReplicaSet with replicas > 0 is the
// one running `expectedTag` — i.e. the old ReplicaSets have fully
// drained post-promotion. Returns when drained OR timeoutMs elapses.
async function waitForDrain(expectedTag, timeoutMs = 120_000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      // List RS name + replicas + image. Filter: replicas > 0 AND image tag != expected.
      const raw = execSync(
        `kubectl get rs -n ${NS} ` +
        `-o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.spec.replicas}{"|"}{.spec.template.spec.containers[0].image}{"\\n"}{end}'`,
        { encoding: "utf8" },
      );
      const stragglers = raw.split("\n").filter((line) => {
        if (!line.trim()) return false;
        const [, replicas, image] = line.split("|");
        const tag = (image || "").split(":").pop();
        return Number(replicas) > 0 && tag !== expectedTag;
      });
      if (stragglers.length === 0) {
        log(`drain complete (only ${expectedTag} RS has replicas)`);
        return;
      }
    } catch (e) {
      log(`waitForDrain transient: ${e.message}`);
    }
    await sleep(2000);
  }
  log("waitForDrain timed out — moving on");
}

// True iff the Rollout is in the paused-for-promotion state (new RS
// healthy behind previewService, awaiting manual promote).
function isRolloutPaused() {
  try {
    const out = execSync(
      `kubectl get rollout ${ROLLOUT_NAME} -n ${NS} ` +
      `-o jsonpath='{.status.pauseConditions[*].reason}'`,
      { encoding: "utf8" },
    ).trim();
    return out.includes("BlueGreenPause");
  } catch {
    return false;
  }
}

function promoteRollout() {
  log(`promoting rollout ${ROLLOUT_NAME}`);
  execSync(
    `kubectl argo rollouts promote ${ROLLOUT_NAME} -n ${NS}`,
    { stdio: "inherit" },
  );
}

// Block until Octopus has surfaced a pending Manual Intervention on the
// given task (typically a few seconds after Deploy Manifests completes
// and the Rollout reports paused).
async function waitForInterruption(taskId, timeoutMs = 300_000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const r = await octoGet(`/api/${SPACE_ID}/interruptions?regarding=${taskId}&pendingOnly=true`);
    const item = (r.Items || [])[0];
    if (item) {
      log(`interruption ${item.Id} pending on task ${taskId}`);
      return item;
    }
    await sleep(2500);
  }
  throw new Error(`timed out waiting for interruption on task ${taskId}`);
}

async function submitInterruption(interruption, result = "Proceed", notes = "Approved via demo recorder") {
  // The interruption must be assigned to the current user before we can
  // submit a response. The take-responsibility endpoint is idempotent.
  await octoPut(`/api/${SPACE_ID}/interruptions/${interruption.Id}/responsible`, {});
  await octoPost(`/api/${SPACE_ID}/interruptions/${interruption.Id}/submit`, {
    Instructions: interruption.Form?.Values || null,
    Notes: notes,
    Result: result,
  });
  log(`interruption ${interruption.Id} submitted: ${result}`);
}

async function octoPut(p, body) {
  const r = await fetch(`${OCTO_URL}${p}`, {
    method: "PUT",
    headers: { "X-Octopus-ApiKey": OCTO_KEY, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!r.ok) throw new Error(`octo PUT ${p} → ${r.status}: ${await r.text()}`);
  return r.json().catch(() => ({}));
}

async function waitForTaskState(taskId, wantedStates, timeoutMs = 300_000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const t = await octoGet(`/api/tasks/${taskId}`);
    if (wantedStates.includes(t.State)) return t;
    await sleep(4000);
  }
  throw new Error(`timed out waiting for ${wantedStates.join("|")}`);
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

// Inject a sticky "what you're watching" banner at the top of any page.
// Survives navigation (re-injected after each goto). Tells the viewer
// what scene we're in so they don't have to guess.
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

// The kubectl panel is plain HTML now (see ensureTtyd) — its layout is
// fully under our control. No post-load CSS surgery needed. We keep the
// function as a no-op shim so the scene code reads the same.
async function fitTtyd(_page) { /* nothing to fit anymore */ }

// WebM recordings don't capture the OS cursor, so a Playwright click
// looks like the page just reacts on its own. Inject a synthetic cursor
// + button highlight + a slow approach animation so the audience can
// see WHERE we clicked and that it was a click. Returns the bounding
// box of the clicked element for the caller's interest.
async function clickVisibly(page, selector, label) {
  const el = page.locator(selector).first();
  const box = await el.boundingBox();
  if (!box) throw new Error(`clickVisibly: ${selector} has no bounding box`);
  const cx = Math.round(box.x + box.width / 2);
  const cy = Math.round(box.y + box.height / 2);

  // Inject (or update) the fake cursor + highlight overlay. CSS-only,
  // fixed-position so navigation doesn't break it.
  await page.evaluate(({ cx, cy, sel, label }) => {
    const ensure = (id, tag = "div") => {
      let n = document.getElementById(id);
      if (!n) { n = document.createElement(tag); n.id = id; document.documentElement.appendChild(n); }
      return n;
    };

    // The cursor itself — an SVG arrow, fixed-position so it sits over
    // the page regardless of scroll.
    const cur = ensure("__demo_cursor");
    cur.innerHTML = `<svg width="28" height="28" viewBox="0 0 24 24" style="filter:drop-shadow(0 2px 4px rgba(0,0,0,0.6))">
      <path d="M5 3 L5 19 L9 15 L11 21 L14 20 L12 14 L18 14 Z" fill="#ffffff" stroke="#000" stroke-width="1.5" stroke-linejoin="round"/>
    </svg>`;
    cur.style.cssText = [
      "position:fixed",
      "left:0",
      "top:0",
      "z-index:2147483646",
      "pointer-events:none",
      "transform:translate(40vw,50vh)",
      "transition:transform 1.2s cubic-bezier(.45,.05,.55,.95)",
    ].join(";");

    // Highlight ring under the cursor target. Drawn outside the element
    // so we don't perturb the page's own layout.
    const ring = ensure("__demo_ring");
    const target = document.querySelector(sel);
    if (target) {
      const r = target.getBoundingClientRect();
      ring.style.cssText = [
        "position:fixed",
        `left:${r.left - 8}px`,
        `top:${r.top - 8}px`,
        `width:${r.width + 16}px`,
        `height:${r.height + 16}px`,
        "border:3px solid #ffb000",
        "border-radius:8px",
        "box-shadow:0 0 0 9999px rgba(0,0,0,0.0), 0 0 24px rgba(255,176,0,0.7)",
        "z-index:2147483645",
        "pointer-events:none",
        "animation:__demo_pulse 0.9s ease-in-out infinite alternate",
        "opacity:1",
        "transition:opacity 0.3s",
      ].join(";");
    }

    // Keyframes (idempotent).
    if (!document.getElementById("__demo_kf")) {
      const s = document.createElement("style");
      s.id = "__demo_kf";
      s.textContent = `
        @keyframes __demo_pulse { from{box-shadow:0 0 14px rgba(255,176,0,0.6)} to{box-shadow:0 0 28px rgba(255,176,0,0.95)} }
        @keyframes __demo_ripple { from{transform:scale(0.4);opacity:0.9} to{transform:scale(2.5);opacity:0} }
      `;
      document.head.appendChild(s);
    }
    return { cx, cy };
  }, { cx, cy, sel: selector, label: label || "" });

  // Move synthetic cursor to the target. We use the same coords for
  // Playwright's real mouse so :hover effects (if any) trigger.
  await page.mouse.move(Math.round(cx / 2), Math.round(cy / 2), { steps: 25 });
  await sleep(150);
  await page.evaluate(({ cx, cy }) => {
    const c = document.getElementById("__demo_cursor");
    if (c) c.style.transform = `translate(${cx - 2}px, ${cy - 2}px)`;
  }, { cx, cy });
  await page.mouse.move(cx, cy, { steps: 30 });
  await sleep(1400); // let the audience read the highlight

  // Click ripple — a brief expanding circle at the cursor.
  await page.evaluate(({ cx, cy }) => {
    const r = document.createElement("div");
    r.style.cssText = [
      "position:fixed",
      `left:${cx - 14}px`,
      `top:${cy - 14}px`,
      "width:28px",
      "height:28px",
      "border-radius:50%",
      "background:rgba(255,176,0,0.6)",
      "z-index:2147483647",
      "pointer-events:none",
      "animation:__demo_ripple 0.6s ease-out forwards",
    ].join(";");
    document.documentElement.appendChild(r);
    setTimeout(() => r.remove(), 700);
  }, { cx, cy });
  await sleep(250);

  await el.click();
  // Fade the ring out so the post-click UI is unobscured.
  await page.evaluate(() => {
    const ring = document.getElementById("__demo_ring");
    if (ring) { ring.style.opacity = "0"; setTimeout(() => ring.remove(), 600); }
    const cur = document.getElementById("__demo_cursor");
    if (cur) { setTimeout(() => cur.remove(), 600); }
  });
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

// ---------- main ----------
(async () => {
  if (!OCTO_KEY) throw new Error("OCTOPUS_API_KEY missing in .env");

  const ttyd = ensureTtyd();
  await sleep(800);

  // ----- Pre-recording (off-camera) -----
  // Normalize: if a prior demo left the rollout paused, promote +
  // drain before we open the browser. Then resolve previous + next
  // versions (kicking the CI build if needed). All of this can take
  // several minutes; do it BEFORE creating the recording context so
  // the resulting WebM only contains the actual demo.
  if (isRolloutPaused()) {
    log("pre: rollout currently paused — promoting + waiting for drain");
    try { promoteRollout(); } catch (e) { log(`promote failed (continuing): ${e.message}`); }
    try {
      const newTag = execSync(
        `kubectl get rs -n ${NS} -o jsonpath='{range .items[*]}{.spec.replicas}{"|"}{.spec.template.spec.containers[0].image}{"\\n"}{end}'`,
        { encoding: "utf8" },
      ).split("\n")
        .filter(Boolean)
        .map((l) => l.split("|"))
        .filter(([r]) => Number(r) > 0)
        .map(([, img]) => img.split(":").pop())
        .pop() || "";
      if (newTag) await waitForDrain(newTag, 90_000);
    } catch (e) { log(`baseline drain skipped: ${e.message}`); }
  }

  const { previousVersion, release } = await resolveRelease();

  log("launching headed chromium with single-tab recordVideo");
  const browser = await chromium.launch({ headless: false, slowMo: 200 });
  // Wider viewport gives the terminal more horizontal room for kubectl -o wide.
  const VIEW = { width: 1680, height: 1000 };
  const ctx = await browser.newContext({
    viewport: VIEW,
    recordVideo: { dir: OUT, size: VIEW },
    ignoreHTTPSErrors: true,
  });
  const page = await ctx.newPage();

  try {
    // ----- Scene 1: log into Octopus (off-screen prelude) -----
    log("scene 1: login");
    await octoLogin(page);

    // ----- Scene 2: kubectl 'before' -----
    log("scene 2: kubectl (before)");
    await page.goto(TTYD_URL, { waitUntil: "domcontentloaded" });
    await fitTtyd(page);
    await banner(page, `Before deploy — single live ReplicaSet running ${previousVersion}; both Services target it`);
    await sleep(12_000);

    // ----- Scene 3: submit deploy, follow Octopus task to the gate -----
    log("scene 3: submit deploy + watch task to manual-intervention pause");
    const { taskId, version } = await submitDeploy(release);
    // The build dispatch from resolveRelease() already kicked off the
    // auto-release trigger fan-out (18 sibling Dev deploys queued).
    // Take them out so our task isn't stuck behind them.
    await cancelOtherQueued(taskId);
    const taskUrl = `${OCTO_URL}/app#/${SPACE_ID}/tasks/${taskId}`;
    await page.goto(taskUrl, { waitUntil: "domcontentloaded" });
    await dismissOctoChrome(page);
    await banner(page, `Deploy triggered — ${PROJECT_SLUG} release ${version} → Dev / ${TENANT_NAME}`);
    const interruption = await waitForInterruption(taskId);
    // Refresh so the audience sees the "Awaiting Manual Intervention"
    // banner Octopus surfaces on the task page once a Manual step pauses.
    await page.reload({ waitUntil: "domcontentloaded" });
    await dismissOctoChrome(page);
    await banner(page, "Manual Intervention — Octopus is paused at the gate, awaiting approval");
    await sleep(10_000);

    // ----- Scene 4: kubectl 'paused' — new RS staged behind preview -----
    log("scene 4: kubectl (paused state)");
    await page.goto(TTYD_URL, { waitUntil: "domcontentloaded" });
    await fitTtyd(page);
    await banner(page, "Paused — preview Service now targets the new ReplicaSet; active still on the old one");
    await sleep(15_000);

    // ----- Scene 5: preview hostname (new version) -----
    log("scene 5: preview app (new version)");
    await page.goto(PREVIEW_URL, { waitUntil: "domcontentloaded" });
    await banner(page, `Preview hostname — bg-* serves the new version (${version}) behind the gate`);
    await sleep(8_000);

    // ----- Scene 6: active hostname (still old) -----
    log("scene 6: active app (still old)");
    await page.goto(APP_URL, { waitUntil: "domcontentloaded" });
    await banner(page, "Active hostname — still on the previous version; no traffic flipped yet");
    await sleep(8_000);

    // ----- Scene 7: approve in Octopus by actually clicking Proceed -----
    // Take responsibility via API first (otherwise the buttons aren't
    // active for the current user), then drive the click in the
    // browser so the audience sees the button get hit. Fall back to
    // API submit if no candidate button matches (selectors can shift
    // between Octopus versions).
    log("scene 7: approve gate via UI click + wait for task success");
    await octoPut(`/api/${SPACE_ID}/interruptions/${interruption.Id}/responsible`, {});
    await page.goto(taskUrl, { waitUntil: "domcontentloaded" });
    await dismissOctoChrome(page);
    await banner(page, "Reviewer clicks Proceed — Octopus runs the Promote Rollout step");
    await sleep(3_000);

    // Octopus sometimes renders a "Take Responsibility" button first even
    // when the API responsible-assignment succeeded; click it so the
    // Proceed button becomes active before we go for it.
    for (const sel of [
      'button:has-text("Take responsibility")',
      'button:has-text("Take Responsibility")',
    ]) {
      const b = page.locator(sel).first();
      if (await b.isVisible().catch(() => false)) {
        log(`pre-click ${sel}`);
        await clickVisibly(page, sel, "Take responsibility");
        await sleep(1500);
        break;
      }
    }

    let clicked = false;
    for (const sel of [
      'button:has-text("Proceed")',
      'button:has-text("Submit Response")',
      '[data-testid="proceed-button"]',
      'button[name="proceed"]',
    ]) {
      const btn = page.locator(sel).first();
      if (await btn.isVisible().catch(() => false)) {
        log(`clicking ${sel}`);
        await clickVisibly(page, sel, "Proceed");
        clicked = true;
        break;
      }
    }
    if (!clicked) {
      log("no Proceed button matched — falling back to API submit");
      await submitInterruption(interruption, "Proceed");
    }
    await waitForTaskState(taskId, ["Success", "Failed"]);
    await banner(page, "Task green — promote + drain completed inside the Promote Rollout step");
    await sleep(4_000);

    // ----- Scene 8: kubectl after drain -----
    log("scene 8: kubectl (drained)");
    await page.goto(TTYD_URL, { waitUntil: "domcontentloaded" });
    await fitTtyd(page);
    await banner(page, `Single live ReplicaSet again — ${version} is serving on both Services`);
    await sleep(8_000);

    // ----- Scene 9: active hostname (now new version) -----
    // Cache-bust query string + reload — without this Chromium serves
    // the cached page from scene 6 (still-old version).
    log("scene 9: active app (now new)");
    await page.goto(`${APP_URL}?v=${version}`, { waitUntil: "domcontentloaded" });
    await page.reload({ waitUntil: "domcontentloaded" });
    await banner(page, `Active hostname — now serving release ${version}`);
    await sleep(10_000);

    log("done");
  } finally {
    await ctx.close();
    await browser.close();
    if (ttyd && ttyd.close) ttyd.close();
  }

  const webms = fs.readdirSync(OUT)
    .filter((f) => f.endsWith(".webm"))
    .map((f) => ({ f, mtime: fs.statSync(path.join(OUT, f)).mtimeMs }))
    .sort((a, b) => b.mtime - a.mtime);
  if (!webms.length) {
    log("no WebM produced");
    process.exit(1);
  }
  const src = path.join(OUT, webms[0].f);
  const dst = path.join(OUT, "bg-preview.mp4");
  log(`ffmpeg: ${path.relative(REPO_ROOT, src)} → ${path.relative(REPO_ROOT, dst)}`);
  execSync(
    `ffmpeg -y -i "${src}" -c:v libx264 -pix_fmt yuv420p -crf 23 -preset fast "${dst}"`,
    { stdio: "inherit" },
  );
  const sizeMb = (fs.statSync(dst).size / 1024 / 1024).toFixed(2);
  log(`written: ${path.relative(REPO_ROOT, dst)} (${sizeMb} MiB)`);
})().catch((err) => {
  console.error("[record-bgp] ERROR:", err.message);
  process.exit(1);
});
