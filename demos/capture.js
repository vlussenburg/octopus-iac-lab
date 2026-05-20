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

async function octoLogin(page, user = OCTO.user, pass = OCTO.pass) {
  await page.goto(`${OCTO.base}/app#/users/sign-in`, { waitUntil: 'domcontentloaded' });
  await page.waitForTimeout(2500);
  await page.fill('input[type="text"]', user);
  await page.fill('input[type="password"]', pass);
  await page.click('button[type="submit"]');
  await page.waitForTimeout(4000);
}

// Switch to a different Octopus user. Hits /api/users/logout to drop the
// server-side session, clears cookies, then signs in fresh. Used by the
// locked-down-prod-pool demo to contrast what admin / developer /
// prod-deployer see.
async function octoSwitchUser(page, user, pass) {
  await page.goto(`${OCTO.base}/api/users/logout`, { waitUntil: 'domcontentloaded' }).catch(() => {});
  await page.context().clearCookies();
  await octoLogin(page, user, pass);
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
  await dismissHelpSidebar(page);
  await page.screenshot({ path: path.join(OUT, `${slug}.png`), fullPage: false });
}

// Navigate to a task page, expand all log sections, scroll the
// gate-check step into view, and screenshot the viewport. Octopus's
// task log uses an inner virtualised scroll container, so fullPage:true
// only captures the visible chunk — scrolling to the section we care
// about is the reliable path.
async function captureTaskLogAtGateCheck(page, taskUrl, slug) {
  // Octopus's task-log UI uses a virtualised inner-scroll container —
  // fullPage:true only captures the visible viewport's worth. The
  // /api/tasks/{id}/raw endpoint returns the whole run as plain text;
  // we render it inside a synthetic page that pretty-prints just the
  // gate-check section, then screenshot that.
  const taskIdMatch = taskUrl.match(/ServerTasks-\d+/);
  if (!taskIdMatch) {
    console.log(`    bad task URL for ${slug}`);
    return;
  }
  const taskId = taskIdMatch[0];
  const apiBase = OCTO.base.replace(/\/$/, '');
  const ctx = await page.context();
  const cookies = await ctx.cookies();
  // Cookie auth doesn't include the API-key header — but the user is
  // already signed in as admin via octoLogin, so the raw endpoint will
  // honour the session cookie.
  const resp = await page.request.get(`${apiBase}/api/tasks/${taskId}/raw`);
  const fullLog = await resp.text();
  // Crop to the "Production gate check" section + ~30 lines around it.
  const lines = fullLog.split('\n');
  // Find the LAST occurrence of "Leased worker ... gate check" — the
  // actual step execution line where the worker pool name is logged.
  // Slice forward to either the marker output (prod case) or the
  // "no prod-only-check" line (dev case) plus a few lines of tail.
  const startMatch = (() => {
    for (let i = 0; i < lines.length; i++) {
      if (/Executing Production gate check.*on .*-pool-worker/.test(lines[i])) return i;
    }
    return lines.findIndex(l => /Production gate check/.test(l));
  })();
  const start = Math.max(0, startMatch - 6);
  // End: 2 lines after the LAST marker / non-prod-pool message, or 50 lines down.
  const endMatch = (() => {
    for (let i = lines.length - 1; i >= 0; i--) {
      if (/prod-only-check|non-prod pool/.test(lines[i])) return i + 2;
    }
    return Math.min(lines.length, startMatch + 50);
  })();
  const snippet = lines.slice(start, endMatch).join('\n');
  await page.setViewportSize({ width: 1600, height: 1100 });
  const html = `<!doctype html><html><head><title>${slug}</title>
    <style>
      body{font-family:'SF Mono','Menlo','Consolas',monospace;font-size:14px;background:#0d1117;color:#e6edf3;padding:32px;margin:0;white-space:pre-wrap;line-height:1.55}
      .h{color:#7ee787;font-weight:bold;font-size:18px;margin-bottom:16px;border-bottom:1px solid #30363d;padding-bottom:10px}
      .marker{color:#ffa657;font-weight:bold}
      .lease{color:#79c0ff;font-weight:bold}
    </style></head><body>
    <div class="h">${slug} — /api/tasks/${taskId}/raw (Production gate check step)</div>
    ${snippet
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/(\[prod-only-check\][^\n]*)/g, '<span class="marker">$1</span>')
      .replace(/(\(no \/usr\/local\/bin\/prod-only-check\.sh[^\n]*\))/g, '<span class="marker">$1</span>')
      .replace(/(Leased worker[^\n]*)/g, '<span class="lease">$1</span>')
      .replace(/(Executing Production gate check[^\n]*)/g, '<span class="lease">$1</span>')
    }
    </body></html>`;
  await page.setContent(html);
  await page.waitForTimeout(500);
  await page.screenshot({ path: `${OUT}/${slug}.png`, fullPage: true });
  // Reset viewport so subsequent shots match the lab-wide 1440x1000.
  await page.setViewportSize({ width: 1440, height: 1000 });
  console.log(`  [${slug}] (raw-log gate-check excerpt, rendered)`);
}

// On a task page, switch to the Task Log tab and expand every
// collapsible section so the verbose per-step output (script body,
// environment info, etc.) is visible in the screenshot. Octopus's task
// UI defaults to collapsed; the "View Settings → Expand → All" menu is
// the manual equivalent.
async function expandAllInTaskLog(page) {
  try {
    await page.click('a:has-text("Task Log"), button:has-text("Task Log"), [role="tab"]:has-text("Task Log")', { timeout: 4000 });
    await page.waitForTimeout(2000);
  } catch (e) {
    console.log(`    task-log tab not found: ${e.message}`);
  }
  try {
    await page.click('button:has-text("View settings"), [aria-label="View settings"]', { timeout: 4000 });
    await page.waitForTimeout(800);
    // "Expand" group has four radios: Interesting / All / Errors / None.
    // Target the "All" radio via Playwright's role-based locator.
    await page.getByRole('radio', { name: 'All' }).click({ timeout: 3000 });
    await page.waitForTimeout(2500);
    await page.keyboard.press('Escape').catch(() => {});
    // Click outside the menu to close it.
    await page.click('h1, [role="heading"]', { timeout: 2000 }).catch(() => {});
    await page.waitForTimeout(800);
  } catch (e) {
    console.log(`    expand-all skipped: ${e.message}`);
  }
}

// The Help Sidebar steals ~300px on the right of every Octopus page. Close it
// before screenshotting so the content area is the focus.
async function dismissHelpSidebar(page) {
  try {
    await page.click('button[aria-label="Close help panel"], button[aria-label="Close help sidebar"], [data-testid="close-help-sidebar"]', { timeout: 750 });
    await page.waitForTimeout(500);
  } catch {}
}

// --- demos ------------------------------------------------------------

const DEMOS = {
  'locked-down-prod-pool': async (page) => {
    const pools     = `${OCTO.base}/app#/Spaces-2/infrastructure/workers`;
    const prodPool  = `${OCTO.base}/app#/Spaces-2/infrastructure/workerpools/WorkerPools-22`;
    const proj      = `${OCTO.base}/app#/Spaces-2/projects/locked-down-prod-pool-randomquotes`;
    const variables = `${proj}/variables`;
    const process   = `${proj}/deployments/process`;
    // Prod + Dev tasks for release 1.0.5-demo — the canonical pair.
    const prodTask  = `${OCTO.base}/app#/Spaces-2/tasks/ServerTasks-1096`;
    const devTask   = `${OCTO.base}/app#/Spaces-2/tasks/ServerTasks-1095`;
    const usersList = `${OCTO.base}/app#/configuration/users`;
    const teamsList = `${OCTO.base}/app#/Spaces-2/configuration/teams`;

    // === Admin's view ============================================
    await octoLogin(page);
    // Infrastructure overview — Workers landing shows both pools + workers.
    await shot(page, 'ld-01-admin-workers',       pools, 5000);
    // prod-pool detail — the polling tentacle registered into it.
    await shot(page, 'ld-02-admin-prod-pool',     prodPool, 5000);
    // System-wide users — `developer` + `prod-deployer` demo accounts.
    await shot(page, 'ld-03-admin-users',         usersList, 4000);
    // Teams page — `developers` + `prod-deployers` with their role bindings.
    await shot(page, 'ld-04-admin-teams',         teamsList, 4000);
    // The locked-down demo project's process — gate-check step visible.
    await shot(page, 'ld-05-admin-process',       process, 5500);
    // Project variables — Project.WorkerPool with env-scoped rows.
    await shot(page, 'ld-06-admin-variables',     variables, 4500);
    // Production deploy task log — proves prod-pool-worker ran the step.
    // Scroll the expanded log down so the gate-check step output is in
    // the viewport. (fullPage doesn't capture Octopus's inner-scroll
    // log container; the raw log view is a separate page we render
    // directly via the rawLog URL.)
    await captureTaskLogAtGateCheck(page, prodTask, 'ld-07-admin-prod-task');
    // Dev deploy task log — same step, no marker output (the contrast).
    await captureTaskLogAtGateCheck(page, devTask, 'ld-08-admin-dev-task');

    // === Developer's view (no WorkerView, no LibVarSet edit) =====
    await octoSwitchUser(page, 'developer', 'Password01!');
    // Worker pools — should be empty / "no permissions" message.
    await shot(page, 'ld-09-developer-workers',   pools, 5000);
    // Project process — process page loads but worker pool dropdowns
    // are empty for a step that uses WorkerPoolVariable.
    await shot(page, 'ld-10-developer-process',   process, 5500);
    // Variables — read-only (LibraryVariableSetEdit absent → can't
    // change the env-scoped Project.WorkerPool).
    await shot(page, 'ld-11-developer-variables', variables, 4500);

    // === Prod-Deployer's view (full Worker* + LibVarSet edit) ====
    await octoSwitchUser(page, 'prod-deployer', 'Password01!');
    // Worker pools — both visible, prod-pool selectable.
    await shot(page, 'ld-12-prod-deployer-workers', pools, 5000);
    // Variables — editable.
    await shot(page, 'ld-13-prod-deployer-variables', variables, 4500);
  },
  'smoke-step-template': async (page) => {
    await octoLogin(page);
    const tplList = `${OCTO.base}/app#/Spaces-2/library/steptemplates`;
    const tpl     = `${OCTO.base}/app#/Spaces-2/library/steptemplates/ActionTemplates-1`;
    const proj    = `${OCTO.base}/app#/Spaces-2/projects/smoke-step-template-randomquotes`;
    // Library landing showing the custom step template.
    await shot(page, 'ss-01-library',          tplList, 4500);
    // Step template detail — script body + parameters.
    await shot(page, 'ss-02-template',         tpl, 5000);
    // Parameters tab.
    try {
      await page.click(`button:has-text("Parameters"), a:has-text("Parameters")`, { timeout: 3000 });
      await page.waitForTimeout(1800);
      await page.screenshot({ path: `${OUT}/ss-03-parameters.png`, fullPage: false });
      console.log(`  [ss-03-parameters] (tab: Parameters)`);
    } catch (e) { console.log(`    skipped ss-03-parameters: ${e.message}`); }
    // Project deployment process — shows 4 steps including the smoke step.
    await shot(page, 'ss-04-project-process',  `${proj}/deployments/process`, 5000);
    // Latest release — task log will show the iteration table once deployed.
    await shot(page, 'ss-05-project-releases', `${proj}/deployments/releases`, 4000);
  },
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
    // Project's deployment process page: shows the process_template step
    // AND its expansion (template's child steps indented underneath) — the
    // before-and-after in a single view.
    await shot(page, 'pt-05-project-process',    `${proj}/deployments/process`, 5000);
    await shot(page, 'pt-06-project-releases',   `${proj}/deployments/releases`, 4000);
    await shot(page, 'pt-07-release-expanded',   `${proj}/deployments/releases/2.0.0-demo`, 4000);
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
