#!/usr/bin/env node
// Demo screenshot capture — one-shot Playwright runner.
//
// Re-runnable proof-of-demo: log into Octopus + Argo CD against the running
// lab, navigate to each demo's notable pages, save PNGs to ./demos/out/.
// The captured set is the same one referenced from each demo PR's body
// (hosted on the `demo-screenshots` release).
//
// Usage:
//   node demos/capture.js                 # capture everything on this branch
//   node demos/capture.js platform-hub    # just this demo's flow
//
// Env:
//   OCTO_URL           default http://localhost:8090
//   OCTO_USER          default admin
//   OCTO_PASS          default Password01!  (from compose/docker-compose.yml)
//   ARGOCD_URL         default http://argocd.localtest.me:8080
//   ARGOCD_USER        default admin
//   ARGOCD_PASS        required for argo-* demos (kubectl -n argocd
//                      get secret argocd-initial-admin-secret -o
//                      jsonpath='{.data.password}' | base64 -d)

const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

const OCTO = {
  base: process.env.OCTO_URL || 'http://localhost:8090',
  user: process.env.OCTO_USER || 'admin',
  pass: process.env.OCTO_PASS || 'Password01!',
};
const ARGOCD = {
  base: process.env.ARGOCD_URL || 'http://argocd.localtest.me:8080',
  user: process.env.ARGOCD_USER || 'admin',
  pass: process.env.ARGOCD_PASS,
};

const OUT = path.resolve(__dirname, 'out');
fs.mkdirSync(OUT, { recursive: true });

// --- helpers ----------------------------------------------------------

async function octoLogin(page) {
  await page.goto(`${OCTO.base}/app#/users/sign-in`, { waitUntil: 'domcontentloaded' });
  await page.waitForTimeout(2500);
  await page.fill('input[type="text"]', OCTO.user);
  await page.fill('input[type="password"]', OCTO.pass);
  await page.click('button[type="submit"]');
  await page.waitForTimeout(4000);
}

async function argoLogin(page) {
  if (!ARGOCD.pass) throw new Error('ARGOCD_PASS env var required for Argo CD demos');
  await page.goto(`${ARGOCD.base}/login`, { waitUntil: 'domcontentloaded' });
  await page.waitForTimeout(2500);
  const inputs = page.locator('input');
  await inputs.nth(0).fill(ARGOCD.user);
  await inputs.nth(1).fill(ARGOCD.pass);
  await page.click('button:has-text("Sign In"), button[type="submit"]');
  await page.waitForURL(/applications/i, { timeout: 15000 });
  await page.waitForTimeout(3000);
}

async function shot(page, slug, url, waitMs = 4500) {
  console.log(`  [${slug}] ${url}`);
  await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 25000 });
  await page.waitForTimeout(waitMs);
  await page.keyboard.press('Escape').catch(() => {});
  await page.screenshot({ path: path.join(OUT, `${slug}.png`), fullPage: false });
}

// --- demos ------------------------------------------------------------

const DEMOS = {
  'process-template': async (page) => {
    await octoLogin(page);
    const tpl = `${OCTO.base}/app#/Spaces-2/platform-hub/process-templates/k8s-tenanted-app`;
    const proj = `${OCTO.base}/app#/Spaces-2/projects/process-template-randomquotes`;
    // Template definition (single-route SPA — tabs are buttons, not paths).
    await shot(page, 'pt-01-template',           tpl, 6000);
    // Click each tab in the template editor.
    for (const [slug, tab] of [
      ['pt-02-parameters', 'Parameters'],
      ['pt-03-versions',   'Versions'],
      ['pt-04-settings',   'Settings'],
    ]) {
      try {
        await page.click(`button:has-text("${tab}"), a:has-text("${tab}")`, { timeout: 3000 });
        await page.waitForTimeout(2000);
        await page.screenshot({ path: `${OUT}/${slug}.png`, fullPage: false });
        console.log(`  [${slug}] (tab: ${tab})`);
      } catch (e) { console.log(`    skipped ${slug}: ${e.message}`); }
    }
    // Project: process at demo branch + the consuming release showing expansion.
    await shot(page, 'pt-05-project-releases',   `${proj}/deployments/releases`, 4000);
    await shot(page, 'pt-06-release-expanded',   `${proj}/deployments/releases/1.0.0-demo`, 4000);
  },
  'platform-hub': async (page) => {
    await octoLogin(page);
    const p = `${OCTO.base}/app#/Spaces-2/projects/platform-hub-opa-randomquotes`;
    await shot(page, 'pha-01-process',   `${p}/deployments/process`);
    await shot(page, 'pha-02-variables', `${p}/variables`);
    // Pick the latest release; release version is whatever CI emitted.
    await shot(page, 'pha-03-release',   `${p}/deployments/releases`);
    // The success + failure tasks are stable URLs once captured; tweak per run.
    // Run with REPLICAS=5 prompted-value to surface the Gatekeeper denial.
  },
  'blue-green': async (page) => {
    await octoLogin(page);
    const p = `${OCTO.base}/app#/Spaces-2/projects/blue-green-randomquotes`;
    await shot(page, 'bg-01-process', `${p}/deployments/process`);
    await shot(page, 'bg-02-release', `${p}/deployments/releases`);
  },
  'octopus-native-bg': async (page) => {
    await octoLogin(page);
    const p = `${OCTO.base}/app#/Spaces-2/projects/octopus-native-bg-randomquotes`;
    await shot(page, 'nbg-01-process', `${p}/deployments/process`);
    await shot(page, 'nbg-02-release', `${p}/deployments/releases`);
  },
  'bg-preview': async (page) => {
    await octoLogin(page);
    const p = `${OCTO.base}/app#/Spaces-2/projects/bg-preview-randomquotes`;
    await shot(page, 'gbg-01-process', `${p}/deployments/process`);
    await shot(page, 'gbg-02-release', `${p}/deployments/releases`);
  },
  'argo-ephemeral': async (page) => {
    await argoLogin(page);
    await shot(page, 'argocd-app-preview-pr-25-tree',
      `${ARGOCD.base}/applications/argocd/randomquotes-preview-pr-25?view=tree&resource=`);
  },
  'argo-sealed-secrets': async (page) => {
    await argoLogin(page);
    await shot(page, 'argocd-app-preview-pr-26-tree',
      `${ARGOCD.base}/applications/argocd/randomquotes-preview-pr-26?view=tree&resource=`);
  },
  'apps': async (page) => {
    // Live app shots — no auth.
    const APPS = {
      'ephemeral-pr-25':            'http://argo-preview-pr-25.localtest.me:8080/',
      'sealed-secrets-pr-26':       'http://argo-preview-pr-26.localtest.me:8080/',
      'blue-green-active':          'http://local-blue-green-acme-corp-dev.localtest.me:8080/',
      'octopus-native-bg':          'http://local-octopus-native-bg-acme-corp-dev.localtest.me:8080/',
      'bg-preview-active':          'http://local-bg-preview-acme-corp-dev.localtest.me:8080/',
      'bg-preview-preview':         'http://bg-local-bg-preview-acme-corp-dev.localtest.me:8080/',
      'platform-hub-opa-acme':      'http://argo-local-acme-corp-dev.localtest.me:8080/',
    };
    for (const [slug, url] of Object.entries(APPS)) {
      await shot(page, slug, url, 1500);
    }
  },
};

(async () => {
  const want = process.argv[2];
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 1000 }, ignoreHTTPSErrors: true });
  const page = await ctx.newPage();

  if (want && DEMOS[want]) {
    console.log(`>>> ${want}`);
    await DEMOS[want](page);
  } else {
    for (const [name, fn] of Object.entries(DEMOS)) {
      console.log(`>>> ${name}`);
      try { await fn(page); } catch (e) { console.log(`    skipped: ${e.message}`); }
    }
  }
  await browser.close();
  console.log(`\nDone. Output in ${OUT}/`);
})();
