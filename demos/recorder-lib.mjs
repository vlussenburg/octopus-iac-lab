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

// Poll a task until its State matches one of `wantedStates`.
export async function waitForTaskState(env, taskId, wantedStates, timeoutMs = 300_000) {
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
