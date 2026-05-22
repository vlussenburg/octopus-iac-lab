#!/usr/bin/env node
// Records a WebM of the canonical `randomquotes` deploy on main.
//
// Focus: the locked-down worker-pool story from PR #105 —
//   - Project.WorkerPool is an env-scoped variable on the project
//     (resolves to prod-pool on Production, unscoped/default elsewhere)
//   - prod-pool is the static pool the polling tentacle in compose/ registers to
//   - the deployment process binds its workers via worker_pool_variable so
//     selection is data-driven, not hardcoded per step
//
// Scenes:
//   1. Login
//   2. Project variables — Project.WorkerPool with the env-scoped value
//   3. Infrastructure → Workers → prod-pool — show the registered tentacle
//   4. Deployment process step — worker pool variable binding
//   5. Trigger a Dev deploy via API → switch to task page → wait Success
//   6. Live app — fully promoted
//
// Requires: ffmpeg, kubectl context for the lab cluster, .env with OCTOPUS_API_KEY.

import {
  loadEnv, sleep, octoLogin, octoPost, octoGet, watchDeployment, saveRecording, launchRecorder,
  resolveProject, resolveEnv, resolveTenant, requireReleases, refreshReleaseSnapshot, verifyDeployed, cancelSiblingDeploys,
  banner, dismissOctoChrome, makeTtyd,
} from "./recorder-lib.mjs";

const env = loadEnv();
const PROJECT_SLUG = "randomquotes";
const SPACE_ID     = "Spaces-2";
const TENANT_NAME  = "acme-corp";
const NS           = "randomquotes-local-acme-corp-dev";
const APP_URL      = "http://local-acme-corp-dev.localtest.me:8080/";
const TTYD_PORT    = 7686;

const log = (...a) => console.log("[record-main]", ...a);

const ttyd = makeTtyd({
  port: TTYD_PORT,
  // Latest Deployment + active Service + Running pods only. Drops stale
  // generations from prior deploys that would otherwise clutter the panel.
  kubectlCmd: `(kubectl get deploy -n ${NS} --sort-by=.metadata.creationTimestamp -o wide 2>/dev/null | tail -3; ` +
              ` echo; kubectl get svc -n ${NS} -o wide 2>/dev/null; ` +
              ` echo; kubectl get pods -n ${NS} -l app=randomquotes --field-selector=status.phase=Running -o wide 2>/dev/null)`,
});

// Redeploy the latest existing release — CI is what creates releases (see
// .github/workflows/build.yml), recorders never should.
async function redeployLatest({ projectId, envId, tenantId }) {
  const releases = await octoGet(env, `/api/${SPACE_ID}/projects/${projectId}/releases?take=1`);
  if (!releases.Items.length) throw new Error(`no releases for ${projectId} — push to GitHub or run build.yml first`);
  const release = releases.Items[0];
  await refreshReleaseSnapshot(env, release.Id);
  const deploy = await octoPost(env, `/api/${SPACE_ID}/deployments`, {
    ReleaseId: release.Id, EnvironmentId: envId, TenantId: tenantId,
  });
  return { taskId: deploy.TaskId, version: release.Version };
}

(async () => {
  const [{ id: projectId }, devEnvId, tenantId] = await Promise.all([
    resolveProject(env, PROJECT_SLUG),
    resolveEnv(env, "Dev"),
    resolveTenant(env, TENANT_NAME),
  ]);
  log(`resolved: project=${projectId} env=${devEnvId} tenant=${tenantId}`);
  await requireReleases(env, projectId, 2);

  ttyd.start();
  const { browser, ctx, page } = await launchRecorder();

  try {
    log("scene 1: login");
    await octoLogin(page, env);

    log("scene 2: project variables — env-scoped Project.WorkerPool");
    await page.goto(`${env.OCTO_URL}/app#/${SPACE_ID}/projects/${PROJECT_SLUG}/variables`, { waitUntil: "domcontentloaded" });
    await dismissOctoChrome(page);
    await banner(page, "Project.WorkerPool — env-scoped to Production → prod-pool (static, locked-down)");
    await sleep(10_000);

    log("scene 3: prod-pool workers");
    await page.goto(`${env.OCTO_URL}/app#/${SPACE_ID}/infrastructure/workers`, { waitUntil: "domcontentloaded" });
    await banner(page, "prod-pool — static pool, polling tentacle from compose/ registers here");
    await sleep(8_000);

    log("scene 4: deployment process step");
    await page.goto(`${env.OCTO_URL}/app#/${SPACE_ID}/projects/${PROJECT_SLUG}/deployments/process`, { waitUntil: "domcontentloaded" });
    await banner(page, "Process steps bind workers via worker_pool_variable — data-driven, not hardcoded");
    await sleep(10_000);

    log("scene 5: trigger Dev deploy + watch task");
    const { taskId, version } = await redeployLatest({ projectId, envId: devEnvId, tenantId });
    await cancelSiblingDeploys(env, taskId);
    await watchDeployment(env, page, taskId, {
      bannerText: `Deploy ${PROJECT_SLUG} ${version} → Dev / ${TENANT_NAME} (no prod-pool needed for Dev)`,
    });
    await verifyDeployed(NS, version);
    await banner(page, "Task green — Dev resolved to the default worker pool, Production would resolve to prod-pool");
    await sleep(6_000);

    log("scene 6: kubectl panel");
    await page.goto(ttyd.url, { waitUntil: "domcontentloaded" });
    await banner(page, `Cluster — randomquotes ${version} live in ${NS}`);
    await sleep(8_000);

    log("scene 7: live app");
    await page.goto(APP_URL, { waitUntil: "domcontentloaded" });
    await banner(page, `Live app — randomquotes ${version} on ${TENANT_NAME} / Dev`);
    await sleep(8_000);

    log("done");
  } finally {
    await saveRecording(page, "main");
    await ctx.close();
    await browser.close();
    ttyd.stop();
  }
})();
