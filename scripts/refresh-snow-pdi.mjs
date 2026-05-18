// Refresh ServiceNow PDI credentials by logging into
// developer.servicenow.com via Playwright and scraping the active
// instance details. Writes SERVICENOW_URL + SERVICENOW_PASSWORD into
// .env in-place (other keys preserved), then exits.
//
// Inputs (read from ../.env):
//   DEV_SNOW_USERNAME — developer portal email
//   DEV_SNOW_PASSWORD — developer portal password
//   DEV_SNOW_MFA      — base32 TOTP seed (the "MFA string" from Authy enrolment)
//
// Flags:
//   HEADED=1          — show browser (default headless)
//   DEBUG=1           — extra logs + dump screenshot on error
//   SLOWMO=200        — slow down actions for debugging

import { chromium } from "playwright";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ENV_PATH = path.resolve(__dirname, "..", ".env");

// ---------- env loader (preserve unknown keys, no shell sourcing) ----------

function readEnv() {
  const text = fs.readFileSync(ENV_PATH, "utf8");
  const map = new Map();
  for (const line of text.split("\n")) {
    const m = line.match(/^([A-Z_][A-Z0-9_]*)=(.*)$/);
    if (m) map.set(m[1], m[2]);
  }
  return { text, map };
}

function writeEnvUpdates(updates) {
  const { text } = readEnv();
  let out = text;
  for (const [k, v] of Object.entries(updates)) {
    const re = new RegExp(`^${k}=.*$`, "m");
    if (re.test(out)) {
      out = out.replace(re, `${k}=${v}`);
    } else {
      out = out.replace(/\n?$/, `\n${k}=${v}\n`);
    }
  }
  fs.writeFileSync(ENV_PATH, out);
}

// ---------- TOTP (RFC 6238, HMAC-SHA1, 6 digits, 30s period) ----------

function totp(secretBase32, when = Date.now()) {
  const clean = secretBase32.replace(/\s+/g, "").toUpperCase().replace(/=+$/, "");
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  let bits = "";
  for (const c of clean) {
    const i = alphabet.indexOf(c);
    if (i < 0) throw new Error(`Invalid base32 char: ${c}`);
    bits += i.toString(2).padStart(5, "0");
  }
  const bytes = Buffer.alloc(Math.floor(bits.length / 8));
  for (let i = 0; i < bytes.length; i++) {
    bytes[i] = parseInt(bits.slice(i * 8, i * 8 + 8), 2);
  }
  const counter = Math.floor(when / 1000 / 30);
  const counterBuf = Buffer.alloc(8);
  counterBuf.writeBigUInt64BE(BigInt(counter));
  const h = crypto.createHmac("sha1", bytes).update(counterBuf).digest();
  const offset = h[h.length - 1] & 0x0f;
  const code = ((h[offset] & 0x7f) << 24) |
               ((h[offset + 1] & 0xff) << 16) |
               ((h[offset + 2] & 0xff) << 8) |
                (h[offset + 3] & 0xff);
  return (code % 1_000_000).toString().padStart(6, "0");
}

// ---------- helpers ----------

const DEBUG = !!process.env.DEBUG;
const log = (...args) => console.error("[snow]", ...args);
const dbg = (...args) => DEBUG && console.error("[snow:dbg]", ...args);

async function dumpOnError(page, name) {
  try {
    const file = path.resolve(__dirname, `snow-debug-${name}.png`);
    await page.screenshot({ path: file, fullPage: true });
    log(`screenshot → ${file}`);
    const html = await page.content();
    fs.writeFileSync(file.replace(".png", ".html"), html);
  } catch (e) {
    log("could not dump:", e.message);
  }
}

// ---------- main ----------

async function main() {
  const { map } = readEnv();
  const username = map.get("DEV_SNOW_USERNAME");
  const password = map.get("DEV_SNOW_PASSWORD");
  const mfa = map.get("DEV_SNOW_MFA");
  if (!username || !password || !mfa) {
    throw new Error("DEV_SNOW_USERNAME / DEV_SNOW_PASSWORD / DEV_SNOW_MFA missing from .env");
  }

  const headed = !!process.env.HEADED;
  const slowMo = parseInt(process.env.SLOWMO || "0", 10);

  log(`launching chromium (${headed ? "headed" : "headless"})`);
  const browser = await chromium.launch({
    headless: !headed,
    slowMo,
    args: [
      "--disable-blink-features=AutomationControlled",
      "--no-sandbox",
      "--ignore-certificate-errors",
    ],
  });
  const ctx = await browser.newContext({
    viewport: { width: 1400, height: 900 },
    userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36",
  });
  // Hide navigator.webdriver and other automation tells before any script runs.
  await ctx.addInitScript(() => {
    Object.defineProperty(navigator, "webdriver", { get: () => undefined });
    Object.defineProperty(navigator, "languages", { get: () => ["en-US", "en"] });
    Object.defineProperty(navigator, "plugins", { get: () => [1, 2, 3, 4, 5] });
  });
  const page = await ctx.newPage();

  // Track auth-stage HTTP failures so we can fail loudly instead of
  // waiting 60s for a URL that will never appear.
  let authError = null;
  page.on("response", async (resp) => {
    const url = resp.url();
    if (/idp\/idx\/(identify|challenge\/answer)/i.test(url) && resp.status() >= 400) {
      authError = `Okta ${resp.status()} at ${url.split("/").pop()} — check DEV_SNOW_USERNAME / DEV_SNOW_PASSWORD`;
    }
    if (DEBUG && /idx|authn|signin|sso_auth|primaryauth|x_snc_sso|developer\.servicenow\.com\/api|\/dev\.do|instance/i.test(url) && !/\.(svg|png|jpg|css|woff|js)(\?|$)/i.test(url)) {
      let body = "";
      try { body = (await resp.text()).slice(0, 400); } catch {}
      dbg(`HTTP ${resp.status()} ${url.slice(0, 100)} ${body.replace(/\s+/g, " ").slice(0, 200)}`);
    }
  });
  if (DEBUG) {
    page.on("framenavigated", (f) => {
      if (f === page.mainFrame()) dbg("nav →", f.url().slice(0, 120));
    });
  }
  // Expose to the catch handler below.
  page._authError = () => authError;

  try {
    log("navigating to developer portal");
    await page.goto("https://developer.servicenow.com/dev.do", { waitUntil: "load" });

    // The hash route #!/manage-instance doesn't auto-redirect anon visitors
    // to SSO — we need to click the "Sign in" button in the top nav first.
    const signInBtn = page.locator('a:has-text("Sign in"), button:has-text("Sign in")').first();
    try {
      await signInBtn.waitFor({ state: "visible", timeout: 15_000 });
      log("clicking Sign in");
      await signInBtn.click();
    } catch {
      dbg("no Sign in button — already authed?");
    }

    // SSO redirect chain: developer.servicenow.com → ssosignon → signon.servicenow.com.
    // Wait for either a credential field to actually render, OR for the
    // manage-instance UI to appear (already authed case).
    log("waiting for login form OR authed landing");
    await Promise.race([
      page.waitForSelector('input[type="email"], input[name="username"], input#username, input[autocomplete="username"], input[type="password"]', { timeout: 60_000, state: "visible" }),
      page.waitForURL(/dev\.do.*manage-instance/i, { timeout: 60_000 }),
    ]);
    dbg("post-wait url:", page.url());

    // ----- email step -----
    const userField = page.locator('input[type="email"], input[name="username"], input#username, input[autocomplete="username"]').first();
    if (await userField.isVisible().catch(() => false)) {
      log("typing email");
      await userField.click();
      await userField.pressSequentially(username, { delay: 25 });
      const nextBtn = page.locator('button[type="submit"], button:has-text("Next")').first();
      await nextBtn.click({ timeout: 5_000 });

      // ----- password step (appears after Next) -----
      const passField = page.locator('input[type="password"], input[name="password"], input#password').first();
      await passField.waitFor({ state: "visible", timeout: 15_000 });
      log("typing password");
      await passField.click();
      await passField.pressSequentially(password, { delay: 25 });
      // Specific Okta-style submit button; wait for React to enable it.
      const submit = page.locator('#challenge-authenticator-submit, button[type="submit"]').first();
      await submit.waitFor({ state: "visible", timeout: 5_000 });
      for (let i = 0; i < 30; i++) {
        if (!(await submit.isDisabled().catch(() => true))) break;
        await page.waitForTimeout(200);
      }
      log("submitting credentials");
      // Tried: .click(), .press("Enter"), pressSequentially. None fired the
      // network POST. Force via DOM requestSubmit to bypass any handler tricks.
      await page.evaluate(() => {
        const btn = document.getElementById("challenge-authenticator-submit");
        const form = btn?.closest("form");
        if (form?.requestSubmit) form.requestSubmit(btn);
        else btn?.click();
      });
    } else {
      dbg("no login form — assuming already authed");
    }

    // ----- MFA step -----
    // After Sign in, either we land on dev portal (trusted device) or we get
    // an MFA challenge. Wait for OTP input OR manage-instance to appear.
    log("waiting for MFA OR portal landing");
    const otpSelector = 'input[name="answer"], input[name="otp"], input[name="code"], input[autocomplete="one-time-code"], input[inputmode="numeric"], input[type="tel"]';
    const otpRace = await Promise.race([
      page.waitForSelector(otpSelector, { timeout: 30_000, state: "visible" }).then(() => "otp"),
      page.waitForURL(/developer\.servicenow\.com\/dev\.do/i, { timeout: 30_000 }).then(() => "portal"),
    ]).catch(() => null);

    if (otpRace === "otp") {
      // Factor chooser may appear; if so click authenticator first.
      const factorChooser = page.locator('button:has-text("Google Authenticator"), button:has-text("Authenticator"), a:has-text("Authenticator"), button:has-text("Enter Code")').first();
      if (await factorChooser.isVisible().catch(() => false)) {
        log("choosing authenticator factor");
        await factorChooser.click().catch(() => {});
      }
      const otpField = page.locator(otpSelector).first();
      const code = totp(mfa);
      log(`entering TOTP ${code}`);
      await otpField.fill(code);
      const verify = page.locator('button:has-text("Verify"), button:has-text("Submit"), button:has-text("Next"), button[type="submit"]').first();
      await verify.click({ timeout: 5_000 }).catch(() => {});
    } else {
      dbg("no MFA challenge — trusted device or already authed");
    }

    // ----- land on dev portal -----
    log("waiting for developer portal");
    await page.waitForURL(/developer\.servicenow\.com\/dev\.do/i, { timeout: 60_000 });
    await page.waitForLoadState("networkidle").catch(() => {});

    // Hit the portal's own JSON APIs using the authenticated browser context.
    // Cleaner than DOM scraping a modal-covered React page.
    log("checking instance awake state");
    const awake = await page.evaluate(async () => {
      const r = await fetch("/api/snc/v1/dev/check_instance_awake", { credentials: "include" });
      return r.ok ? r.json() : { result: { error: r.status } };
    });
    dbg("awake:", JSON.stringify(awake.result));

    if (awake.result?.isHibernating) {
      log("instance hibernating — waking via wake_up endpoint");
      await page.evaluate(async () => {
        await fetch("/api/snc/v1/dev/wake_up_instance", { method: "POST", credentials: "include" });
      });
      // Poll up to 5 min for wake to complete.
      for (let i = 0; i < 60; i++) {
        await page.waitForTimeout(5_000);
        const w = await page.evaluate(async () => {
          const r = await fetch("/api/snc/v1/dev/check_instance_awake", { credentials: "include" });
          return r.json();
        });
        dbg(`wake poll ${i+1}: ${JSON.stringify(w.result)}`);
        if (w.result?.isAwake) break;
      }
    }

    log("fetching instance credentials");
    // ServiceNow API requires X-UserToken (the g_ck global the portal renders
    // into the page). Plain fetch() from page.evaluate doesn't include it and
    // we get 401, even though same-origin cookies are sent.
    const magic = await page.evaluate(async () => {
      const csrf = window.g_ck || "";
      const r = await fetch("/api/snc/fetch_magic_link_url", {
        credentials: "include",
        headers: { Accept: "application/json", "X-UserToken": csrf },
      });
      const text = await r.text();
      try { return { status: r.status, ...JSON.parse(text) }; }
      catch { return { status: r.status, raw: text.slice(0, 300) }; }
    });
    dbg("magic response:", JSON.stringify(magic).slice(0, 300));
    const magicUrl = magic.result?.url;
    if (!magicUrl) {
      log("magic link API returned no url");
      await dumpOnError(page, "no-magic");
      throw new Error("could not fetch instance credentials");
    }
    dbg("magic url:", magicUrl);
    const parsed = new URL(magicUrl);
    const instanceUrl = parsed.origin + "/";
    const instancePw = decodeURIComponent(parsed.searchParams.get("user_password") || "");
    const instanceUser = parsed.searchParams.get("user_name") || "admin";

    if (!instancePw) {
      throw new Error("no user_password in magic link");
    }

    log(`instance: ${instanceUrl}`);
    log(`user: ${instanceUser}`);
    log(`password: (length ${instancePw.length})`);

    writeEnvUpdates({
      SERVICENOW_URL: instanceUrl,
      SERVICENOW_USERNAME: instanceUser,
      SERVICENOW_PASSWORD: instancePw,
    });
    log(".env updated: SERVICENOW_URL, SERVICENOW_USERNAME, SERVICENOW_PASSWORD");
  } catch (err) {
    const authErr = page._authError?.();
    if (authErr) {
      log("ERROR:", authErr);
    } else {
      log("ERROR:", err.message.split("\n")[0]);
    }
    await dumpOnError(page, "fatal");
    process.exitCode = 1;
    if (headed && process.env.PAUSE_ON_ERROR) {
      log("PAUSE_ON_ERROR=1 — browser left open. Press Ctrl+C when done.");
      await new Promise(() => {});
    }
  } finally {
    await browser.close().catch(() => {});
  }
}

main();
