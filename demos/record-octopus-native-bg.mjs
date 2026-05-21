#!/usr/bin/env node
// Records a single-tab WebM of the blue-green demo (PR #28):
//
// One Playwright page navigates URL→URL through the story, so the recording
// is a single WebM (and a single MP4 after ffmpeg) instead of Playwright's
// default per-page recording.
//
// Sequence:
//   1. ttyd events stream (so the audience sees "what was here before")
//   2. Octopus task page (deploy fires while we're on this tab)
//   3. ttyd events again (pod create, image pull, ready)
//   4. Octopus task page (final green checkmarks)
//   5. App URL (live result)
//
// Requires:
//   - ttyd, ffmpeg on PATH
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
const PROJECT_SLUG = "octopus-native-bg-randomquotes";
const PROJECT_ID = "Projects-2";
const SPACE_ID = "Spaces-2";
const DEV_ENV_ID = "Environments-1";
const TENANT_NAME = "acme-corp";
const NS = "randomquotes-local-octopus-native-bg-acme-corp-dev";
const APP_URL = "http://local-octopus-native-bg-acme-corp-dev.localtest.me:8080/";
const TTYD_PORT = 7685;
const TTYD_URL = `http://localhost:${TTYD_PORT}/`;
const OCTOPUS_ADMIN_USER = process.env.OCTO_USER || "admin";
const OCTOPUS_ADMIN_PASS = process.env.OCTO_PASS || "Password01!";

const log = (...a) => console.log("[record-bg]", ...a);
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
        `kubectl get deployment,rs,svc,pods -n ${NS} -o wide 2>/dev/null`,
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

async function triggerDeploy() {
  // Pick a release whose image tag DIFFERS from what's currently live in
  // the pod — without that, the Rollout sees no change and the demo plays
  // out silently against an already-deployed version.
  let liveTag = "";
  try {
    const img = execSync(
      `kubectl get pods -n ${NS} -l app=randomquotes ` +
      `-o jsonpath='{.items[0].spec.containers[0].image}'`,
    ).toString().trim();
    liveTag = img.split(":").pop() || "";
    log(`live pod image tag: ${liveTag || "(unknown)"}`);
  } catch {
    log("could not read live pod image — falling back to latest release");
  }

  const releases = await octoGet(`/api/${SPACE_ID}/projects/${PROJECT_ID}/releases?take=10`);
  const candidate = releases.Items.find((r) => r.Version !== liveTag) || releases.Items[0];
  log(`deploying release ${candidate.Version} (≠ live tag ${liveTag || "?"})`);

  const tenants = await octoGet(`/api/${SPACE_ID}/tenants?name=${TENANT_NAME}`);
  const tenantId = tenants.Items[0].Id;

  const dep = await octoPost(`/api/${SPACE_ID}/deployments`, {
    ReleaseId: candidate.Id,
    EnvironmentId: DEV_ENV_ID,
    TenantId: tenantId,
    ProjectId: PROJECT_ID,
  });
  log(`deployment ${dep.Id} → task ${dep.TaskId}`);
  return { taskId: dep.TaskId, version: candidate.Version };
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

    // ----- Scene 2: kubectl 'before' — current version running -----
    log("scene 2: kubectl (before — show current running version)");
    await page.goto(TTYD_URL, { waitUntil: "domcontentloaded" });
    await fitTtyd(page);
    await banner(page, "Cluster state before deploy — note current image tag on the active ReplicaSet");
    await sleep(12_000);

    // ----- Scene 3: trigger deploy + watch Octopus task to completion -----
    // The intermediate kubectl scene (showing pods coming up mid-deploy)
    // got pulled — between the trigger and the post-promotion drain
    // there's a fair bit of Octopus-side waiting, so we stay on the
    // Octopus task page until the deployment lands instead of
    // cutting back and forth.
    log("scene 3: trigger deploy + stay on Octopus task until success");
    const { taskId, version } = await triggerDeploy();
    const taskUrl = `${OCTO_URL}/app#/${SPACE_ID}/tasks/${taskId}`;
    await page.goto(taskUrl, { waitUntil: "domcontentloaded" });
    await dismissOctoChrome(page);
    await banner(page, `Deploy triggered — ${PROJECT_SLUG} release ${version} → Dev / ${TENANT_NAME}`);
    await waitForTaskState(taskId, ["Success", "Failed"]);
    await banner(page, "Deploy complete — Octopus task green");
    await sleep(5_000);

    // ----- Scene 4: kubectl 'after' — new version live + old RS draining -----
    // The actual blue-green payoff. We poll the cluster directly and
    // only hold this scene until the old ReplicaSets actually scale to
    // 0 (then linger 5s so the audience sees the settled state). Beats
    // a fixed sleep that either underruns or sits on a static screen
    // for too long.
    log("scene 4: kubectl (after — new version + drain)");
    await page.goto(TTYD_URL, { waitUntil: "domcontentloaded" });
    await fitTtyd(page);
    await banner(page, `Now serving release ${version} — old ReplicaSet drains 3 → 0 after scaleDownDelaySeconds`);
    await waitForDrain(version);
    await sleep(5_000);

    // ----- Scene 6: live app -----
    log("scene 6: live app");
    await page.goto(APP_URL, { waitUntil: "domcontentloaded" });
    await banner(page, `Live app — randomquotes ${version} serving on the active Service`);
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
  const dst = path.join(OUT, "octopus-native-bg.mp4");
  log(`ffmpeg: ${path.relative(REPO_ROOT, src)} → ${path.relative(REPO_ROOT, dst)}`);
  execSync(
    `ffmpeg -y -i "${src}" -c:v libx264 -pix_fmt yuv420p -crf 23 -preset fast "${dst}"`,
    { stdio: "inherit" },
  );
  const sizeMb = (fs.statSync(dst).size / 1024 / 1024).toFixed(2);
  log(`written: ${path.relative(REPO_ROOT, dst)} (${sizeMb} MiB)`);
})().catch((err) => {
  console.error("[record-bg] ERROR:", err.message);
  process.exit(1);
});
