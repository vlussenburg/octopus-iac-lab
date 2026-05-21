#!/usr/bin/env node
// Records a single-tab WebM of the canary demo (PR #58):
//
// Sequence:
//   1. Octopus login (off-camera prelude)
//   2. kubectl panel — "before" state (single stable ReplicaSet)
//   3. Trigger deploy via Octopus API → switch to task page → wait Success
//   4. kubectl panel — canary stepping through 20/40/60/80/100% weights
//   5. Live app URL — fully promoted
//
// Requires: ffmpeg, kubectl context for the lab cluster, .env with OCTOPUS_API_KEY.

import { chromium } from "../scripts/node_modules/playwright/index.mjs";
import { spawn, execSync } from "node:child_process";
import path from "node:path";
import {
  loadEnv, sleep, octoLogin, octoPost, octoGet, waitForTaskState,
  banner, dismissOctoChrome, makeTtyd, OUT,
} from "./recorder-lib.mjs";

const env = loadEnv();
const PROJECT_SLUG = "canary-randomquotes";
const PROJECT_ID   = "Projects-21";
const SPACE_ID     = "Spaces-2";
const DEV_ENV_ID   = "Environments-1";
const TENANT_NAME  = "acme-corp";
const TENANT_ID    = "Tenants-1";
const NS           = "randomquotes-local-canary-acme-corp-dev";
const APP_URL      = "http://local-canary-acme-corp-dev.localtest.me:8080/";
const TTYD_PORT    = 7684;
const VIDEO_NAME   = "canary.webm";

const log = (...a) => console.log("[record-canary]", ...a);

const ttyd = makeTtyd({
  port: TTYD_PORT,
  kubectlCmd: `kubectl get rollouts.argoproj.io,replicaset,svc,pods -n ${NS} -o wide 2>/dev/null`,
});

// Bump the canary by triggering a release with a fresh image tag against
// the Dev/acme-corp slot. Returns { taskId, version }.
async function triggerDeploy() {
  const channels = await octoGet(env, `/api/Spaces-2/projects/${PROJECT_ID}/channels`);
  const channelId = channels.Items[0].Id;
  const version = `0.${Date.now()}`;
  const release = await octoPost(env, "/api/Spaces-2/releases", {
    ProjectId: PROJECT_ID,
    ChannelId: channelId,
    Version: version,
    SelectedPackages: [
      { ActionName: "Deploy Manifests",                       PackageReferenceName: "randomquotes-image", Version: "latest" },
      { ActionName: "Update Argo CD Application Image Tags",  PackageReferenceName: "octopus-iac-lab",    Version: "latest" },
    ],
  });
  const deploy = await octoPost(env, "/api/Spaces-2/deployments", {
    ReleaseId: release.Id, EnvironmentId: DEV_ENV_ID, TenantId: TENANT_ID,
  });
  return { taskId: deploy.TaskId, version };
}

// Wait for the canary to fully drain — old ReplicaSets scaled to 0.
async function waitForDrain(expectedTag, timeoutMs = 120_000) {
  const t0 = Date.now();
  while (Date.now() - t0 < timeoutMs) {
    try {
      const out = execSync(`kubectl get rs -n ${NS} -o json`, { stdio: ["ignore", "pipe", "ignore"] }).toString();
      const j = JSON.parse(out);
      const live = j.items.filter(rs => (rs.status?.replicas ?? 0) > 0);
      if (live.length === 1 && live[0].spec.template.spec.containers[0].image.endsWith(`:${expectedTag}`)) return;
    } catch {}
    await sleep(2_000);
  }
}

(async () => {
  ttyd.start();
  const browser = await chromium.launch({ headless: true });
  const ctx = await browser.newContext({
    viewport: { width: 1680, height: 945 },
    recordVideo: { dir: OUT, size: { width: 1680, height: 945 } },
    ignoreHTTPSErrors: true,
  });
  const page = await ctx.newPage();

  try {
    log("scene 1: login");
    await octoLogin(page, env);

    log("scene 2: kubectl (before)");
    await page.goto(ttyd.url, { waitUntil: "domcontentloaded" });
    await banner(page, "Before deploy — single stable ReplicaSet serving 100% of traffic");
    await sleep(10_000);

    log("scene 3: trigger deploy + watch task");
    const { taskId, version } = await triggerDeploy();
    await page.goto(`${env.OCTO_URL}/app#/${SPACE_ID}/tasks/${taskId}`, { waitUntil: "domcontentloaded" });
    await dismissOctoChrome(page);
    await banner(page, `Deploy triggered — ${PROJECT_SLUG} release ${version} → Dev / ${TENANT_NAME}`);
    await waitForTaskState(env, taskId, ["Success", "Failed"]);
    await banner(page, "Octopus task green — Argo Rollouts now stepping canary weights");
    await sleep(4_000);

    log("scene 4: kubectl (canary progression)");
    await page.goto(ttyd.url, { waitUntil: "domcontentloaded" });
    await banner(page, `Canary rolling — release ${version} stepping 20% → 40% → 60% → 80% → 100%`);
    await waitForDrain(version);
    await sleep(5_000);

    log("scene 5: live app");
    await page.goto(APP_URL, { waitUntil: "domcontentloaded" });
    await banner(page, `Live app — randomquotes ${version} fully promoted on the stable Service`);
    await sleep(10_000);

    log("done");
  } finally {
    await ctx.close();
    await browser.close();
    ttyd.stop();
    const video = await page.video();
    if (video) await video.saveAs(path.join(OUT, VIDEO_NAME));
  }
})();
