#!/usr/bin/env node
// Open ttyd in Playwright at the recorder's viewport size, apply the same
// CSS overrides the recorder uses, take a screenshot. Use to iterate on
// the layout without burning a full deploy/record cycle.

import { chromium } from "../scripts/node_modules/playwright/index.mjs";
import { spawn, execSync } from "node:child_process";
import path from "node:path";
import fs from "node:fs";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const OUT = path.join(__dirname, "out");
fs.mkdirSync(OUT, { recursive: true });
const NS = "randomquotes-local-blue-green-acme-corp-dev";
const TTYD_PORT = 7682;

// Free port + relaunch ttyd
try { execSync(`lsof -ti:${TTYD_PORT} | xargs -r kill`); } catch {}
await new Promise((r) => setTimeout(r, 800));

const watchCmd = `while true; do clear; date '+%H:%M:%S'; echo; ` +
  `kubectl get rollouts.argoproj.io,replicaset,pods -n ${NS} -o wide 2>/dev/null; ` +
  `sleep 2; done`;
const ttyd = spawn("ttyd", [
  "--port", String(TTYD_PORT), "--writable", "--check-origin",
  "--client-option", "fontSize=22",
  "--client-option", "fontFamily=MesloLGS NF,Menlo,monospace",
  "bash", "-c", watchCmd,
], { stdio: "pipe" });
await new Promise((r) => setTimeout(r, 1200));

const browser = await chromium.launch({ headless: true });
const ctx = await browser.newContext({ viewport: { width: 1680, height: 1000 } });
const page = await ctx.newPage();
await page.goto(`http://localhost:${TTYD_PORT}/`, { waitUntil: "domcontentloaded" });
await page.waitForTimeout(2000);

// === inspect raw layout ===
const raw = await page.evaluate(() => {
  const t = document.querySelector("#terminal-container") || document.querySelector(".terminal");
  return t ? {
    selector: t.id ? "#" + t.id : t.className,
    rect: t.getBoundingClientRect(),
    bodyRect: document.body.getBoundingClientRect(),
  } : { error: "no terminal container found" };
});
console.log("RAW layout:", JSON.stringify(raw, null, 2));
await page.screenshot({ path: path.join(OUT, "ttyd-raw.png"), fullPage: false });

// === apply CSS fix (mirror record-blue-green.mjs fitTtyd) ===
await page.addStyleTag({
  content: `
    html, body { margin:0 !important; padding:0 !important; background:#000 !important; overflow:hidden !important; }
    body { padding-top:56px !important; box-sizing:border-box !important; }
  `,
});
// Simulate banner so we can see how the two interact in one screenshot.
await page.evaluate(() => {
  const el = document.createElement("div");
  el.style.cssText = "position:fixed;top:0;left:0;right:0;height:56px;z-index:2147483647;padding:14px 20px;background:linear-gradient(90deg,#0f1f33,#1a3a5c);color:#fff;font:600 18px -apple-system,sans-serif;text-align:center;box-sizing:border-box;";
  el.textContent = "Cluster state before deploy — Rollout + ReplicaSet + Pods";
  document.documentElement.appendChild(el);
  window.dispatchEvent(new Event("resize"));
});
await page.waitForTimeout(1000);

const fixed = await page.evaluate(() => {
  const t = document.querySelector("#terminal-container") || document.querySelector(".terminal");
  return t ? { rect: t.getBoundingClientRect() } : { error: "missing" };
});
console.log("FIXED layout:", JSON.stringify(fixed, null, 2));
await page.screenshot({ path: path.join(OUT, "ttyd-fixed.png"), fullPage: false });

await browser.close();
ttyd.kill("SIGTERM");
console.log("\nScreenshots: demos/out/ttyd-raw.png, demos/out/ttyd-fixed.png");
