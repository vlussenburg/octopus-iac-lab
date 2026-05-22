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

import { spawn, execSync } from "node:child_process";
import {
  loadEnv, sleep, octoLogin, octoPost, octoGet, watchDeployment, saveRecording, launchRecorder,
  resolveProject, resolveEnv, resolveTenant, requireReleases,
  readLiveImageTag, pickDeployableRelease, refreshReleaseSnapshot, verifyDeployed, cancelSiblingDeploys,
  banner, makeTtyd,
} from "./recorder-lib.mjs";

const env = loadEnv();
const PROJECT_SLUG = "canary-randomquotes";
const SPACE_ID     = "Spaces-2";
const TENANT_NAME  = "acme-corp";
const NS           = "randomquotes-local-canary-acme-corp-production";
const APP_URL      = "http://local-canary-acme-corp-production.localtest.me:8080/";
const TTYD_PORT    = 7684;

const log = (...a) => console.log("[record-canary]", ...a);

// `argo rollouts get rollout` is the only kubectl output that surfaces
// canary weight progression (Step N/M, SetWeight, ActualWeight) — the plain
// `get rollouts/rs` output hides it. --no-color strips ANSI so the <pre>
// renders cleanly. Append the pod list for additional ground truth.
const ttyd = makeTtyd({
  port: TTYD_PORT,
  kubectlCmd: `kubectl argo rollouts get rollout randomquotes -n ${NS} --no-color 2>/dev/null; echo; kubectl get pods -n ${NS} -o wide 2>/dev/null`,
});

// Bump the canary by triggering a release with a fresh image tag against
// the Dev/acme-corp slot. Returns { taskId, version }.
// Redeploy a release that differs from what's currently running — picks N+1
// (newer) if available, else N-1. Deploying the live release silently no-ops
// the rollout (Step M/M, weight 100 immediately) so the canary scene has
// nothing to record. CI owns release creation, recorders never should.
async function redeployDifferent({ projectId, envId, tenantId }) {
  const liveTag = readLiveImageTag(NS);
  log(`live image tag: ${liveTag || "(unknown — will deploy latest)"}`);
  const release = await pickDeployableRelease(env, projectId, liveTag);
  log(`picked release ${release.Version} → image tag ${release.imageTag} (≠ live ${liveTag})`);
  await refreshReleaseSnapshot(env, release.Id);
  const deploy = await octoPost(env, "/api/Spaces-2/deployments", {
    ReleaseId: release.Id, EnvironmentId: envId, TenantId: tenantId,
  });
  return { taskId: deploy.TaskId, version: release.imageTag };
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
  const [{ id: projectId }, envId, tenantId] = await Promise.all([
    resolveProject(env, PROJECT_SLUG),
    resolveEnv(env, "Production"),
    resolveTenant(env, TENANT_NAME),
  ]);
  log(`resolved: project=${projectId} env=${envId} tenant=${tenantId}`);
  await requireReleases(env, projectId, 2);
  ttyd.start();
  const { browser, ctx, page } = await launchRecorder();

  try {
    log("scene 1: login");
    await octoLogin(page, env);

    log("scene 2: kubectl (before)");
    await page.goto(ttyd.url, { waitUntil: "domcontentloaded" });
    await banner(page, "Before deploy — single stable ReplicaSet serving 100% of traffic");
    await sleep(10_000);

    log("scene 3: trigger deploy + watch task");
    const { taskId, version } = await redeployDifferent({ projectId, envId, tenantId });
    await cancelSiblingDeploys(env, taskId);
    await watchDeployment(env, page, taskId, {
      bannerText: `Deploy triggered — ${PROJECT_SLUG} release ${version} → Production / ${TENANT_NAME}`,
    });
    await banner(page, "Octopus task green — Argo Rollouts now stepping canary weights");
    await sleep(4_000);

    log("scene 4: kubectl (canary progression)");
    await page.goto(ttyd.url, { waitUntil: "domcontentloaded" });
    await banner(page, `Canary rolling — release ${version} stepping 20% → 40% → 60% → 80% → 100%`);
    await waitForDrain(version);
    await verifyDeployed(NS, version);
    await sleep(5_000);

    log("scene 5: live app");
    await page.goto(APP_URL, { waitUntil: "domcontentloaded" });
    await banner(page, `Live app — randomquotes ${version} fully promoted on the stable Service`);
    await sleep(10_000);

    log("done");
  } finally {
    await saveRecording(page, "canary");
    await ctx.close();
    await browser.close();
    ttyd.stop();
  }
})();
