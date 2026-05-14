#!/usr/bin/env node
// Boot the same kubectl HTML panel the recorder uses, headed-screenshot it
// at the recorder's viewport. Faster than rendering a full webm to dial in
// font size / column widths.

import { chromium } from "../scripts/node_modules/playwright/index.mjs";
import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const OUT = path.join(__dirname, "out");

// Reuse the recorder process so any HTML change auto-picks up: import
// would require refactoring exports; cheaper to spawn it briefly. Instead,
// hit a freshly-spawned tiny server here that mirrors the recorder.
const NS = "randomquotes-local-blue-green-acme-corp-dev";
const PORT = 7682;

const child = spawn("node", ["-e", `
  const http = require('node:http');
  const { exec } = require('node:child_process');
  const html = \`<!doctype html><html><head><meta charset="utf-8"><style>
    html,body { margin:0; padding:0; height:100vh; width:100vw; background:#0b0f17; color:#e6edf3; font:600 14px/1.3 "MesloLGS NF",Menlo,Consolas,monospace; overflow:hidden; }
    body { padding:72px 28px 28px 28px; box-sizing:border-box; }
    pre { margin:0; white-space:pre; }
  </style></head><body><pre id="o">…</pre><script>
    async function t(){const r=await fetch('/k',{cache:'no-store'});document.getElementById('o').textContent=await r.text();}
    t();setInterval(t,2000);
  </script></body></html>\`;
  http.createServer((req,res)=>{
    if(req.url==='/'){res.writeHead(200,{'Content-Type':'text/html'});res.end(html);return;}
    if(req.url==='/k'){exec('kubectl get rollouts.argoproj.io,replicaset,pods -n ${NS} -o wide 2>/dev/null',(e,o)=>{res.writeHead(200);res.end(o||'(empty)');});return;}
    res.writeHead(404);res.end();
  }).listen(${PORT});
`], { stdio: "inherit" });

await new Promise(r => setTimeout(r, 1000));
const browser = await chromium.launch({ headless: false });
const ctx = await browser.newContext({ viewport: { width: 1680, height: 1000 } });
const page = await ctx.newPage();
await page.goto(`http://localhost:${PORT}/`);
await page.waitForTimeout(2500);
// Banner overlay (same as recorder).
await page.evaluate(() => {
  const el = document.createElement("div");
  el.style.cssText = "position:fixed;top:0;left:0;right:0;height:56px;z-index:99;padding:14px 20px;background:linear-gradient(90deg,#0f1f33,#1a3a5c);color:#fff;font:600 18px -apple-system,sans-serif;text-align:center;box-sizing:border-box;";
  el.textContent = "Cluster state before deploy — Rollout + ReplicaSet + Pods";
  document.documentElement.appendChild(el);
});
await page.waitForTimeout(600);
await page.screenshot({ path: path.join(OUT, "panel-check.png") });
await browser.close();
child.kill("SIGTERM");
console.log("→ demos/out/panel-check.png");
