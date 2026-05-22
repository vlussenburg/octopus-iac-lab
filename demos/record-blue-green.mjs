#!/usr/bin/env node
// Records a single-tab WebM of the blue-green demo (PR #28):
//
// Sequence:
//   1. Octopus login (off-camera prelude)
//   2. kubectl panel — "before" state (current image tag on the active ReplicaSet)
//   3. Trigger deploy via Octopus API → switch to task page → wait Success
//   4. kubectl panel — old ReplicaSet drains, new becomes live
//   5. Live app URL — fully promoted
//
// Requires: ffmpeg, kubectl context for the lab cluster, .env with OCTOPUS_API_KEY.

import { execSync } from "node:child_process";
import {
  loadEnv, sleep, octoLogin, octoPost, watchDeployment, saveRecording, launchRecorder,
  resolveProject, resolveEnv, resolveTenant, requireReleases,
  readLiveImageTag, pickDeployableRelease, refreshReleaseSnapshot, verifyDeployed, cancelSiblingDeploys,
  banner, makeTtyd,
} from "./recorder-lib.mjs";

const env = loadEnv();
const PROJECT_SLUG = "blue-green-randomquotes";
const TENANT_NAME  = "acme-corp";
const NS           = "randomquotes-local-blue-green-acme-corp-production";
const APP_URL      = "http://local-blue-green-acme-corp-production.localtest.me:8080/";
const TTYD_PORT    = 7682;

const log = (...a) => console.log("[record-bg]", ...a);

// Include svc so the audience can read the active Service's SELECTOR
// (rollouts-pod-template-hash=<hash>) and visually match it against the
// ReplicaSet hashes — that's where the blue-green switchover happens.
// Restrict pod list to Running only so stale Terminating pods from prior
// runs don't make the "old draining" / "new live" banner misleading.
const ttyd = makeTtyd({
  port: TTYD_PORT,
  kubectlCmd:
    `(kubectl get rollout,svc -n ${NS} -o wide 2>/dev/null; ` +
    ` echo; kubectl get replicaset -n ${NS} -l app=randomquotes -o wide 2>/dev/null | awk 'NR==1 || $3>0'; ` +
    ` echo; kubectl get pods -n ${NS} -l app=randomquotes --field-selector=status.phase=Running -o wide 2>/dev/null)`,
});

// Poll the cluster until the only ReplicaSet with replicas > 0 is the one
// running `expectedTag` — i.e. old ReplicaSets have fully drained post-promotion.
async function waitForDrain(expectedTag, timeoutMs = 120_000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
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

(async () => {
  const [{ id: projectId }, envId, tenantId] = await Promise.all([
    resolveProject(env, PROJECT_SLUG),
    resolveEnv(env, "Production"),
    resolveTenant(env, TENANT_NAME),
  ]);
  log(`resolved: project=${projectId} env=${envId} tenant=${tenantId}`);
  await requireReleases(env, projectId, 2);
  ttyd.start();
  const { browser, ctx, page } = await launchRecorder({ slowMo: 200 });

  try {
    log("scene 1: login");
    await octoLogin(page, env);

    log("scene 2: kubectl (before — show current running version)");
    await page.goto(ttyd.url, { waitUntil: "domcontentloaded" });
    await banner(page, "Cluster state before deploy — note current image tag on the active ReplicaSet");
    await sleep(12_000);

    log("scene 3: trigger deploy + watch task");
    const liveTag = readLiveImageTag(NS);
    log(`live image tag: ${liveTag || "(unknown — first deploy)"}`);
    const release = await pickDeployableRelease(env, projectId, liveTag);
    log(`deploying release ${release.Version} → image ${release.imageTag} (≠ live ${liveTag || "?"})`);
    await refreshReleaseSnapshot(env, release.Id);
    const deploy = await octoPost(env, "/api/Spaces-2/deployments", {
      ReleaseId: release.Id, EnvironmentId: envId, TenantId: tenantId, ProjectId: projectId,
    });
    const { TaskId: taskId } = deploy;
    const version = release.imageTag;
    log(`deployment ${deploy.Id} → task ${taskId}`);
    await cancelSiblingDeploys(env, taskId);
    await watchDeployment(env, page, taskId, {
      bannerText: `Deploy triggered — ${PROJECT_SLUG} release ${version} → Production / ${TENANT_NAME}`,
    });
    await banner(page, "Deploy complete — Octopus task green");
    await sleep(5_000);

    log("scene 4: kubectl (after — new version + drain)");
    await page.goto(ttyd.url, { waitUntil: "domcontentloaded" });
    await banner(page, `Now serving release ${version} — old ReplicaSet drains 3 → 0 after scaleDownDelaySeconds`);
    await waitForDrain(version);
    await verifyDeployed(NS, version);
    await sleep(5_000);

    log("scene 5: live app");
    await page.goto(APP_URL, { waitUntil: "domcontentloaded" });
    await banner(page, `Live app — randomquotes ${version} serving on the active Service`);
    await sleep(10_000);

    log("done");
  } finally {
    await saveRecording(page, "blue-green");
    await ctx.close();
    await browser.close();
    ttyd.stop();
  }
})().catch((err) => {
  console.error("[record-bg] ERROR:", err.message);
  process.exit(1);
});
