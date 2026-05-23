// Shared helpers for demos/record-*.mjs — the elaborate WebM recorders that
// drive Octopus + a side kubectl panel through a scripted scene sequence.
//
// Each demo file imports what it needs from here and contributes:
//   - demo-specific constants (PROJECT_ID, NS, APP_URL, TTYD_PORT)
//   - the scene script (the actual "Scene 1 → … → Scene N" sequence)
//
// Use:
//   import { loadEnv, octoLogin, banner, makeTtyd, ... } from "./recorder-lib.mjs";

import fs from "node:fs";
import path from "node:path";
import http from "node:http";
import { exec } from "node:child_process";
import { fileURLToPath } from "node:url";
import { chromium } from "../scripts/node_modules/playwright/index.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
export const REPO_ROOT = path.resolve(__dirname, "..");
export const OUT = path.join(__dirname, "out");
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

export function loadEnv() {
  const E = envMap();
  return {
    OCTO_URL: E.get("OCTOPUS_URL") || "http://localhost:8090",
    OCTO_KEY: E.get("OCTOPUS_API_KEY"),
    OCTO_USER: process.env.OCTO_USER || "admin",
    OCTO_PASS: process.env.OCTO_PASS || "Password01!",
  };
}

// ---------- generic helpers ----------
export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export async function octoLogin(page, { OCTO_URL, OCTO_USER, OCTO_PASS }) {
  await page.goto(`${OCTO_URL}/app#/users/sign-in`, { waitUntil: "domcontentloaded" });
  await page.waitForTimeout(2500);
  await page.fill('input[type="text"]', OCTO_USER);
  await page.fill('input[type="password"]', OCTO_PASS);
  await page.click('button[type="submit"]');
  await page.waitForTimeout(4000);
}

export async function octoPost(env, p, body) {
  const r = await fetch(`${env.OCTO_URL}${p}`, {
    method: "POST",
    headers: { "X-Octopus-ApiKey": env.OCTO_KEY, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!r.ok) throw new Error(`POST ${p} → ${r.status} ${await r.text()}`);
  return r.json();
}

export async function octoGet(env, p) {
  const r = await fetch(`${env.OCTO_URL}${p}`, {
    headers: { "X-Octopus-ApiKey": env.OCTO_KEY },
  });
  if (!r.ok) throw new Error(`GET ${p} → ${r.status} ${await r.text()}`);
  return r.json();
}

// Look up IDs by slug/name so callers can keep configs free of unstable IDs
// (Project/Environment/Tenant IDs all rotate on `make nuke`). Each helper
// throws if the named resource doesn't exist, since silently returning
// undefined would just produce a confusing 4xx later.
// Returns { id, gitRef } so callers can use the project's default branch
// when posting releases against CaC projects (the API requires it). gitRef
// is null for non-version-controlled projects, which is fine — release POSTs
// for those ignore VersionControlReference.
export async function resolveProject(env, slugOrName) {
  const r = await octoGet(env, `/api/Spaces-2/projects?partialName=${encodeURIComponent(slugOrName)}`);
  const hit = r.Items.find((p) => p.Slug === slugOrName || p.Name === slugOrName);
  if (!hit) throw new Error(`no project '${slugOrName}' (got ${r.Items.map((p) => p.Slug).join(", ")})`);
  return { id: hit.Id, gitRef: hit.PersistenceSettings?.DefaultBranch ?? null };
}

export async function resolveEnv(env, name) {
  const r = await octoGet(env, `/api/Spaces-2/environments?partialName=${encodeURIComponent(name)}`);
  const hit = r.Items.find((e) => e.Name === name);
  if (!hit) throw new Error(`no environment '${name}'`);
  return hit.Id;
}

export async function resolveTenant(env, name) {
  const r = await octoGet(env, `/api/Spaces-2/tenants?partialName=${encodeURIComponent(name)}`);
  const hit = r.Items.find((t) => t.Name === name);
  if (!hit) throw new Error(`no tenant '${name}'`);
  return hit.Id;
}

// Cancel any other Executing/Queued Deploy tasks so the auto-release-trigger
// fan-out (one new release → one auto-deploy per Dev tenant × project, can
// be 6–18 sibling tasks) doesn't clobber the namespace we just demoed.
// Without this, verifyDeployed races against a sibling auto-deploy and
// reports "the cluster disagrees" even though our task succeeded.
//
// Call this AFTER the deploy POST returns (so you know your own taskId) and
// BEFORE waitForTaskState — siblings get cancelled while ours runs.
export async function cancelSiblingDeploys(env, myTaskId) {
  const r = await octoGet(env, `/api/tasks?states=Executing,Queued&take=30`);
  const others = (r.Items || []).filter((t) => t.Id !== myTaskId && /Deploy /.test(t.Description || ""));
  for (const t of others) {
    await fetch(`${env.OCTO_URL}/api/tasks/${t.Id}/cancel`, {
      method: "POST", headers: { "X-Octopus-ApiKey": env.OCTO_KEY },
    }).catch(() => {});
  }
  if (others.length) console.log(`[cancelSiblingDeploys] cancelled ${others.length} sibling Deploy tasks`);
}

// Assert that the cluster actually reflects what Octopus claimed it deployed.
// Octopus's "Success" only means the deploy step exited 0 — it doesn't verify
// the new image is running. Call this AFTER waitForTaskState to catch silent
// drift (stale Deployment lying around, image pull stuck, etc.). Throws on
// mismatch so the recorder fails loudly rather than producing a misleading
// "drain complete" banner.
//
//   verifyDeployed("randomquotes-local-canary-acme-corp-dev", "1.1.122")
//
// `labelSelector` defaults to `app=randomquotes`. Looks at pods that are
// Running + Ready; ignores terminating/old ones.
export async function verifyDeployed(namespace, expectedVersion, { labelSelector = null, timeoutMs = 120_000 } = {}) {
  const t0 = Date.now();
  // Default: no label selector — Octopus's native-BG step labels pods with
  // `Octopus.*` (not `app=randomquotes`), so we'd miss them. Argo Rollouts
  // pods carry `app=randomquotes`. Just match all Running pods in the (per-
  // demo) namespace and check their image tag.
  const selectorFlag = labelSelector ? `-l ${labelSelector} ` : "";
  while (Date.now() - t0 < timeoutMs) {
    try {
      const out = _execSync(
        `kubectl get pods -n ${namespace} ${selectorFlag}` +
        `--field-selector=status.phase=Running -o json`,
        { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] },
      );
      const pods = JSON.parse(out).items.filter((p) =>
        (p.status?.containerStatuses || []).every((c) => c.ready),
      );
      const tags = [...new Set(pods.map((p) =>
        (p.spec?.containers?.[0]?.image || "").split(":").pop(),
      ).filter(Boolean))];
      if (tags.length === 1 && tags[0] === expectedVersion) {
        console.log(`[verifyDeployed] ✓ ${namespace} is running ${expectedVersion} on ${pods.length} pod(s)`);
        return;
      }
      console.log(`[verifyDeployed] waiting — tags=${JSON.stringify(tags)} expected=${expectedVersion}`);
    } catch (e) {
      console.log(`[verifyDeployed] kubectl transient: ${e.message}`);
    }
    await new Promise((r) => setTimeout(r, 3000));
  }
  throw new Error(
    `verifyDeployed: namespace ${namespace} never converged on ${expectedVersion} within ${timeoutMs}ms — ` +
    `recorder thinks deploy succeeded but the cluster disagrees`,
  );
}

// Pick a release that will actually produce visible cluster activity: prefer
// one with a Version newer than what's currently live in the cluster (N+1),
// fallback to any release whose Version differs from live (N-1 — re-deploys
// an older image, still produces a rollout). Without this, the recorder
// deploys the same image that's already running and the rollout silently
// reports Step M/M, weight 100 with no progression visible.
//
// liveTag is the live container image tag — pass null/empty to just return
// the latest release.
import { execSync as _execSync } from "node:child_process";

// Try Running pods first, fall back to the newest Deployment's pod template
// (covers the case where the demo is invoked between BG swaps and no pods
// exist for a few seconds). No label selector — Octopus's native-BG step
// uses Octopus.*-prefixed labels, not `app=randomquotes`, so any default
// selector misses half the demos.
export function readLiveImageTag(namespace) {
  for (const cmd of [
    `kubectl get pods -n ${namespace} --field-selector=status.phase=Running -o jsonpath='{.items[0].spec.containers[0].image}'`,
    `kubectl get deploy -n ${namespace} --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].spec.template.spec.containers[0].image}'`,
  ]) {
    try {
      const img = _execSync(cmd, { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
      const tag = img.split(":").pop() || "";
      if (tag) return tag;
    } catch {}
  }
  return "";
}

// Force the release to re-snapshot project + library variables. Without
// this, a release created before a `tofu apply` that added new variables
// will deploy against the stale snapshot — failing with "No variable named
// 'X' was in scope" even though the variable now exists. Cheap to call; the
// only side effect is re-resolving prompted defaults.
export async function refreshReleaseSnapshot(env, releaseId) {
  await octoPost(env, `/api/Spaces-2/releases/${releaseId}/snapshot-variables`, {});
}

// Returns a release wrapped with a flat `.imageTag` derived from
// SelectedPackages[0].Version — that's the actual container image tag, NOT
// `release.Version` (which is Octopus's metadata version; agent-created
// releases like "1.1.129-bg-scope" routinely wrap an older package like
// 1.1.128). Comparing the wrong field is how we ended up deploying images
// identical to live and seeing canary rollouts no-op.
function imageTagOf(release) {
  // Some projects have multiple package refs; the first is the app image
  // by convention in this lab. Falls back to release.Version for older
  // releases that don't have SelectedPackages populated.
  return release.SelectedPackages?.[0]?.Version || release.Version;
}

export async function pickDeployableRelease(env, projectId, liveTag) {
  const releases = await octoGet(env, `/api/Spaces-2/projects/${projectId}/releases?take=10`);
  if (!releases.Items.length) throw new Error(`no releases for ${projectId}`);
  const wrap = (r) => ({ ...r, imageTag: imageTagOf(r) });
  if (!liveTag) return wrap(releases.Items[0]);
  // Items are newest-first. Find any release whose IMAGE TAG differs from
  // live (release.Version is decoupled from image tag — many releases can
  // wrap the same image, e.g. agent-created "1.1.128-bg-split" → image
  // 1.1.128). Prefer the newest such release.
  const candidates = releases.Items.filter((r) => imageTagOf(r) !== liveTag);
  if (candidates.length) return wrap(candidates[0]);
  throw new Error(
    `no release with image tag ≠ ${liveTag} (all ${releases.Items.length} latest releases wrap ${liveTag}); ` +
    `trigger build.yml to produce a newer image`,
  );
}

// Recorders only ever redeploy existing releases — release creation is owned by
// `.github/workflows/build.yml`. This guard makes a recorder fail fast and loud
// if the project is empty (e.g. a fresh `make nuke` before any push to main),
// rather than dying mid-recording on the first deploy POST.
export async function requireReleases(env, projectId, min = 2) {
  const r = await octoGet(env, `/api/Spaces-2/projects/${projectId}/releases?take=${min}`);
  if (r.TotalResults < min) {
    throw new Error(
      `project ${projectId} has ${r.TotalResults} release(s); recorders need at least ${min}. ` +
      `Trigger .github/workflows/build.yml (or push to main) to create releases.`,
    );
  }
}

// One-stop "watch this deploy" helper: navigates `page` to the task URL,
// dismisses Octopus's chrome, then polls the task to completion. While the
// task is streaming we tail the Task Log (with pinned-bottom scroll so new
// lines stay on camera). When the task transitions to Success/Failed we
// switch to the Task Summary tab and pin the scroll to the top of the page
// so the audience sees the green-check title + Start/End/Duration + the
// step result list — NOT the log tail (which is usually whitespace or
// noisy stderr-equivalent).
//
// Strategy comment for the deploy-completion scroll choice: we click the
// "Task Summary" tab on completion rather than scrolling-to-selector on the
// log view, because Task Summary is a stable, naturally-pinned view that
// always shows the most useful end-state lines together. It survives the
// next React re-render and doesn't drift. linger=8s lets the audience read
// it before we move on.
export async function watchDeployment(env, page, taskId, {
  dismissChrome = true,
  bannerText = null,
  scrollIntervalMs = 2500,
  timeoutMs = 600_000,
  completionLingerMs = 8_000,
  completionBannerText = null,
} = {}) {
  await page.goto(`${env.OCTO_URL}/app#/Spaces-2/tasks/${taskId}`, { waitUntil: "domcontentloaded" });
  if (dismissChrome) await dismissOctoChrome(page);
  if (bannerText) await banner(page, bannerText);

  // Stay on the default Task Summary view during the run: it shows step
  // icons flipping green in-place as the deployment progresses (more
  // legible than a scrolling raw log at recording resolution). Pin every
  // scrollable container to the TOP every few seconds — without this, the
  // inner overflow drifts to the bottom (showing only the last 1–2 steps
  // + whitespace) as new step rows expand. block:'start' on the h1 anchors
  // the camera on the title + tabs so the audience always knows what
  // they're watching.
  const stopPinTop = await pinToTop(page, scrollIntervalMs);
  const finalTask = await waitForTaskState(env, taskId, ["Success", "Failed"], timeoutMs);
  await stopPinTop();

  // Completion: one explicit final scroll-to-top so the camera lands on
  // the green-check title + Ran on/Start/End/Duration table + all-green
  // step list. Then linger so the audience can read it.
  await page.evaluate(() => {
    document.querySelectorAll("*").forEach((el) => {
      const s = getComputedStyle(el);
      if (!/auto|scroll/.test(s.overflowY)) return;
      if (el.scrollHeight > el.clientHeight) el.scrollTo({ top: 0, behavior: "smooth" });
    });
    const h1 = document.querySelector("h1");
    if (h1) h1.scrollIntoView({ behavior: "smooth", block: "start" });
  }).catch(() => {});
  if (completionBannerText) await banner(page, completionBannerText);
  if (completionLingerMs > 0) await sleep(completionLingerMs);
  return finalTask;
}

// Periodically pin every overflow container on the page to the top. Mirror
// of withPinnedScroll but for the opposite anchor — used by watchDeployment
// to keep the Task Summary header on camera instead of letting it drift
// off as the step list expands. Returns a stop() async function.
async function pinToTop(page, intervalMs = 2500) {
  await page.evaluate((intervalMs) => {
    if (window.__demoPinTopTimer) clearInterval(window.__demoPinTopTimer);
    window.__demoPinTopTimer = setInterval(() => {
      document.querySelectorAll("*").forEach((el) => {
        const s = getComputedStyle(el);
        if (!/auto|scroll/.test(s.overflowY)) return;
        if (el.scrollHeight <= el.clientHeight) return;
        if (el.scrollTop > 8) el.scrollTo({ top: 0, behavior: "smooth" });
      });
    }, intervalMs);
  }, intervalMs);
  return async () => {
    await page.evaluate(() => {
      if (window.__demoPinTopTimer) {
        clearInterval(window.__demoPinTopTimer);
        window.__demoPinTopTimer = null;
      }
    }).catch(() => {});
  };
}

// Launch Chromium headless with a recordVideo context. Single entry point so
// every recorder produces identical-sized MP4 frames and there's no
// "some pop a window, some don't" surprise.
export async function launchRecorder({ width = 1680, height = 945, slowMo = 0 } = {}) {
  const browser = await chromium.launch({ headless: true, slowMo });
  const ctx = await browser.newContext({
    viewport: { width, height },
    recordVideo: { dir: OUT, size: { width, height } },
    ignoreHTTPSErrors: true,
  });
  const page = await ctx.newPage();
  return { browser, ctx, page };
}

// Save the page's video as `<slug>.mp4` under demos/out/ and clean up the
// intermediate WebM. Call from inside the recorder's `finally`, BEFORE
// closing ctx/browser (Playwright finalizes the video on page-close; saveAs
// after ctx.close fails). MP4 is the unified output format — plays in
// QuickTime, browsers, GitHub README embeds; WebM doesn't.
export async function saveRecording(page, slug) {
  const video = page.video();
  if (!video) { await page.close(); return null; }
  // Capture the auto-generated `page@hash.webm` path before closing — that's
  // the file Playwright writes during recording. saveAs() copies to our
  // chosen path; the auto-original sticks around forever unless we delete
  // it explicitly, which is how the OUT dir grew 14 stale webms across
  // runs.
  const autoPath = await video.path().catch(() => null);
  await page.close();
  const webmPath = path.join(OUT, `${slug}.webm`);
  await video.saveAs(webmPath).catch(() => {});
  const mp4Path = path.join(OUT, `${slug}.mp4`);
  _execSync(
    `ffmpeg -y -i "${webmPath}" -c:v libx264 -pix_fmt yuv420p -crf 23 -preset fast "${mp4Path}"`,
    { stdio: "inherit" },
  );
  for (const p of [webmPath, autoPath]) {
    if (p && fs.existsSync(p)) fs.unlinkSync(p);
  }
  const sizeMb = (fs.statSync(mp4Path).size / 1024 / 1024).toFixed(2);
  console.log(`[saveRecording] ${path.relative(REPO_ROOT, mp4Path)} (${sizeMb} MiB)`);
  return mp4Path;
}

// Run `asyncFn()` while keeping every overflow:auto/scroll container on the
// page pinned to the bottom when new content arrives there. Used during long
// task-log streams so the latest lines stay on camera. Behavior:
//   - in-browser setInterval (state persists across ticks via WeakMap)
//   - only scrolls when (a) scrollHeight actually grew AND (b) new content
//     is below the current viewport (more than `slackPx` px hidden) — i.e.
//     don't snap when the log already fits or we're already at the bottom
//   - window-level scroll is deliberately NOT touched (Octopus's task log
//     lives in an inner overflow container; scrolling the window just
//     pushes the page header off-camera, which feels jarring)
//   - smooth-behavior scroll so the camera glides instead of snapping
export async function withPinnedScroll(page, asyncFn, { intervalMs = 2500, slackPx = 24 } = {}) {
  await page.evaluate(({ intervalMs, slackPx }) => {
    if (window.__demoScrollTimer) clearInterval(window.__demoScrollTimer);
    const lastH = new WeakMap();
    window.__demoScrollTimer = setInterval(() => {
      document.querySelectorAll("*").forEach((el) => {
        const s = getComputedStyle(el);
        if (!/auto|scroll/.test(s.overflowY)) return;
        if (el.scrollHeight <= el.clientHeight) return;
        const h = el.scrollHeight;
        const grew = h > (lastH.get(el) || 0);
        const hiddenBelow = h - el.clientHeight - el.scrollTop;
        if (grew && hiddenBelow > slackPx) el.scrollTo({ top: h, behavior: "smooth" });
        lastH.set(el, h);
      });
    }, intervalMs);
  }, { intervalMs, slackPx });
  try {
    return await asyncFn();
  } finally {
    await page.evaluate(() => {
      if (window.__demoScrollTimer) { clearInterval(window.__demoScrollTimer); window.__demoScrollTimer = null; }
    }).catch(() => {});
  }
}

// Poll a task until its State matches one of `wantedStates`.
export async function waitForTaskState(env, taskId, wantedStates, timeoutMs = 600_000) {
  const t0 = Date.now();
  while (Date.now() - t0 < timeoutMs) {
    const t = await octoGet(env, `/api/tasks/${taskId}`);
    if (wantedStates.includes(t.State)) return t;
    await sleep(2_000);
  }
  throw new Error(`task ${taskId} didn't reach ${wantedStates.join("|")} within ${timeoutMs}ms`);
}

// Inject a fixed-position banner over the page so the audience sees a label
// describing the current scene. Replaces previous banner if present.
export async function banner(page, label) {
  await page.evaluate((text) => {
    let el = document.getElementById("__demo_banner");
    if (!el) {
      el = document.createElement("div");
      el.id = "__demo_banner";
      Object.assign(el.style, {
        position: "fixed", top: "0", left: "0", right: "0",
        zIndex: "999999",
        background: "#0b0f17", color: "#e6edf3",
        font: '600 16px/1.4 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif',
        padding: "14px 24px",
        borderBottom: "2px solid #7ee787",
        boxShadow: "0 2px 8px rgba(0,0,0,0.5)",
      });
      document.body.appendChild(el);
    }
    el.textContent = text;
  }, label);
}

// Scroll the page's main overflow container by `pixels` (smoothly). Used to
// reveal content below the fold on long pages (insights charts, audit list)
// during a hold without burning a separate scene. Targets the *largest*
// overflow:auto/scroll element on the page — Octopus's main content lives
// in an inner overflow div, not the window.
export async function scrollMainBy(page, pixels = 400) {
  await page.evaluate((dy) => {
    let best = null;
    let bestArea = 0;
    document.querySelectorAll("*").forEach((el) => {
      const s = getComputedStyle(el);
      if (!/auto|scroll/.test(s.overflowY)) return;
      if (el.scrollHeight <= el.clientHeight) return;
      const area = el.clientWidth * el.clientHeight;
      if (area > bestArea) { bestArea = area; best = el; }
    });
    if (best) best.scrollBy({ top: dy, behavior: "smooth" });
    else window.scrollBy({ top: dy, behavior: "smooth" });
  }, pixels);
}

// Draw a coloured ring + pulsing glow around an element so the viewer's eye
// snaps to it. Auto-removes after `durationMs`. No-op if the selector
// doesn't match (e.g. when a user can't see the element — which is itself
// the point sometimes). Multiple highlights can stack via different keys.
// Selector goes through page.locator() so Playwright-syntax pseudo-classes
// like :has-text() and :near() work — using document.querySelectorAll
// directly would throw on those.
export async function highlight(page, selector, { durationMs = 4000, color = "#ff8a00", key = "default" } = {}) {
  await page.evaluate(() => {
    const styleId = "__demo_highlight_style";
    if (document.getElementById(styleId)) return;
    const st = document.createElement("style");
    st.id = styleId;
    st.textContent = `
      @keyframes __demo_pulse {
        0%   { box-shadow: 0 0 0 0 var(--demo-hi), 0 0 0 0 var(--demo-hi); }
        70%  { box-shadow: 0 0 0 14px rgba(255,138,0,0), 0 0 18px 6px var(--demo-hi); }
        100% { box-shadow: 0 0 0 0 rgba(255,138,0,0), 0 0 0 0 var(--demo-hi); }
      }
      .__demo_hi {
        outline: 3px solid var(--demo-hi) !important;
        outline-offset: 3px !important;
        border-radius: 6px !important;
        animation: __demo_pulse 1.4s ease-out infinite !important;
        position: relative !important;
        z-index: 999998 !important;
      }
    `;
    document.head.appendChild(st);
  });

  let handles = [];
  try { handles = await page.locator(selector).elementHandles(); } catch {}
  for (const h of handles) {
    await h.evaluate((el, args) => {
      el.style.setProperty("--demo-hi", args.col);
      el.classList.add("__demo_hi");
      el.dataset.demoHiKey = args.k;
    }, { col: color, k: key }).catch(() => {});
  }

  if (handles.length) {
    await page.evaluate(({ dur, k }) => {
      setTimeout(() => {
        document.querySelectorAll(`[data-demo-hi-key="${k}"]`).forEach((el) => {
          el.classList.remove("__demo_hi");
          delete el.dataset.demoHiKey;
          el.style.removeProperty("--demo-hi");
        });
      }, dur);
    }, { dur: durationMs, k: key });
  }
}

// Log out the current Octopus session and log in fresh as a different
// user. Must clear storage on the *Octopus origin* — if the page is
// currently on a non-Octopus origin (e.g. the ttyd kubectl panel) then
// localStorage.clear() targets the wrong storage and Octopus auto-logs
// in as the previous user from its lingering JWT. So: navigate to
// Octopus sign-in first, clear, reload, then fill the form.
export async function switchUser(page, env, { username, password }) {
  await page.goto(`${env.OCTO_URL}/app#/users/sign-in`, { waitUntil: "domcontentloaded" });
  await page.waitForTimeout(1000);
  await page.context().clearCookies();
  await page.evaluate(() => { try { sessionStorage.clear(); localStorage.clear(); } catch {} });
  await page.reload({ waitUntil: "domcontentloaded" });
  await page.waitForTimeout(2500);
  await page.fill('input[type="text"]', username);
  await page.fill('input[type="password"]', password);
  await page.click('button[type="submit"]');
  await page.waitForTimeout(4000);
}

// Close help sidebar + cookie banner / signup nags Octopus shows.
export async function dismissOctoChrome(page) {
  for (const sel of [
    'button[aria-label="Close help panel"]',
    'button[aria-label="Close help sidebar"]',
    '[data-testid="close-help-sidebar"]',
  ]) {
    try { await page.click(sel, { timeout: 500 }); } catch {}
  }
}

// ---------- kubectl panel (the "ttyd" thing) ----------
// Serves a tiny self-polling HTML page from a Node http server. The page
// runs `kubectlCmd` every 2s server-side and renders the stdout into a <pre>.
// Replaces the actual ttyd binary; xterm.js in headed Chromium had layout
// problems we couldn't beat with CSS.
//
//   const ttyd = makeTtyd({ port: 7682, namespace: "ns", kubectlArgs: "rollouts.argoproj.io,replicaset,svc,pods -n ns -o wide" });
//   ttyd.start();
//   await page.goto(ttyd.url);
//   ttyd.stop();
export function makeTtyd({ port, kubectlCmd }) {
  const url = `http://localhost:${port}/`;
  let server = null;

  const html = `<!doctype html>
<html><head><meta charset="utf-8"><title>cluster</title>
<style>
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
      document.getElementById('out').textContent = await r.text();
      document.getElementById('time').textContent = new Date().toLocaleTimeString();
    } catch (e) { /* ignore */ }
  }
  tick(); setInterval(tick, 2000);
</script>
</body></html>`;

  function start() {
    server = http.createServer((req, res) => {
      if (req.url === "/" || req.url === "/index.html") {
        res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
        res.end(html);
        return;
      }
      if (req.url === "/kubectl") {
        exec(kubectlCmd, { maxBuffer: 1024 * 1024 }, (_err, stdout) => {
          res.writeHead(200, { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store" });
          res.end(stdout || "(no resources yet)");
        });
        return;
      }
      res.writeHead(404); res.end();
    });
    server.listen(port);
  }

  function stop() {
    if (server) server.close();
  }

  return { url, start, stop };
}
