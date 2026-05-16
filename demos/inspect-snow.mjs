// Open the latest snow CR in SNow, dump candidate state-change selectors,
// take a screenshot. Headless, no clicking.

import { chromium } from "../scripts/node_modules/playwright/index.mjs";
import fs from "node:fs";

function envmap(){const t=fs.readFileSync(".env","utf8");const m=new Map();for(const l of t.split("\n")){const x=l.match(/^([A-Z_][A-Z0-9_]*)=(.*)$/);if(x)m.set(x[1],x[2])}return m}
const e=envmap();
const SNOW_URL=e.get("SERVICENOW_URL").replace(/\/$/,"");
const USER="admin", PASS=e.get("SERVICENOW_PASSWORD");
const auth="Basic "+Buffer.from(`${USER}:${PASS}`).toString("base64");
// Find most recent Octopus CR
const r=await fetch(`${SNOW_URL}/api/now/table/change_request?sysparm_query=short_descriptionSTARTSWITHOctopus^ORDERBYDESCsys_created_on&sysparm_limit=1&sysparm_fields=sys_id,number,state,approval`,{headers:{Authorization:auth}}).then(r=>r.json());
const cr=r.result[0];console.log("CR:",cr);
const browser=await chromium.launch({headless:false});
const ctx=await browser.newContext({viewport:{width:1680,height:1000},ignoreHTTPSErrors:true});
const page=await ctx.newPage();
await page.goto(`${SNOW_URL}/login.do`,{waitUntil:"domcontentloaded"});
await page.fill("#user_name",USER);await page.fill("#user_password",PASS);
await page.click('button:has-text("Log in"), #sysverb_login');
await page.waitForLoadState("networkidle",{timeout:30000}).catch(()=>{});
await page.waitForTimeout(2500);
await page.goto(`${SNOW_URL}/nav_to.do?uri=change_request.do?sys_id=${cr.sys_id}`,{waitUntil:"domcontentloaded"});
await page.waitForTimeout(6000);
// Inspect frames
console.log("=== frames ===");
for(const f of page.frames()){console.log(" ",f.name(),f.url())}
const main=page.frame({name:"gsft_main"})||page.mainFrame();
console.log("main frame:",main.name());
// Dump candidate state/approval selectors
const info=await main.evaluate(()=>{
  const out={};
  const states=document.querySelectorAll('select[id*="state"], [data-fieldname="state"]');
  out.state_candidates=Array.from(states).slice(0,5).map(e=>({id:e.id,name:e.name,tag:e.tagName,value:e.value}));
  const approval=document.querySelectorAll('select[id*="approval"], [data-fieldname="approval"]');
  out.approval_candidates=Array.from(approval).slice(0,5).map(e=>({id:e.id,name:e.name,tag:e.tagName,value:e.value}));
  const buttons=document.querySelectorAll('button, input[type="button"], input[type="submit"]');
  out.buttons=Array.from(buttons).slice(0,15).map(e=>({text:(e.textContent||e.value||"").trim().slice(0,40),id:e.id||"",name:e.name||""}));
  return out;
});
console.log("=== form info ===");console.log(JSON.stringify(info,null,2));
await page.screenshot({path:"demos/out/snow-cr-inspect.png",fullPage:false});
console.log("→ demos/out/snow-cr-inspect.png");
await browser.close();
