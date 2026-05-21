# Demo capture

`capture.js` re-runs the screenshot proofs (and optional WebM recordings) shown in each demo PR's body. Output goes to `demos/out/` (gitignored).

## Setup (one-time)

```bash
npm i playwright
npx playwright install chromium
```

## Run

```bash
# Screenshots — every demo
node demos/capture.js

# Just one
node demos/capture.js main                  # canonical randomquotes
node demos/capture.js platform-hub          # PR #46 (demo/platform-hub-opa)
node demos/capture.js blue-green            # PR #28
node demos/capture.js bg-preview            # PR #30
node demos/capture.js octopus-native-bg     # PR #29
node demos/capture.js canary                # PR #58
node demos/capture.js process-template      # PR #92
node demos/capture.js smoke-step-template   # PR #103
node demos/capture.js servicenow-cr-gate    # PR #53 (light shots)
node demos/capture.js argo-ephemeral        # PR #25
node demos/capture.js argo-sealed-secrets   # PR #26
node demos/capture.js apps                  # all live-app URLs

# WebM recording — same scenarios, one .webm per demo in demos/out/
node demos/capture.js --record              # all
node demos/capture.js canary --record       # just one
```

`--record` wraps each demo's context with `recordVideo` — same scenario, just produces a WebM alongside the PNGs. Convert to MP4 if needed: `ffmpeg -i demos/out/<slug>.webm -c:v libx264 -preset slow -crf 22 demos/out/<slug>.mp4`.

The `demo/servicenow-cr-gate` flow has full orchestration in [`capture-snow.mjs`](capture-snow.mjs) (deploy → CR creation → mid-flow PDI approval → resume) — light shots are in `capture.js`'s case above.

## Env

| Var | Default |
|---|---|
| `OCTO_URL` | `http://localhost:8090` |
| `OCTO_USER` / `OCTO_PASS` | `admin` / `Password01!` (from `compose/docker-compose.yml`) |
| `ARGOCD_URL` | `http://argocd.localtest.me:8080` |
| `ARGOCD_USER` / `ARGOCD_PASS` | `admin` / `Password01!` (static lab password, set by `tofu/argocd/`; override via `TF_VAR_argocd_password`) |

The published PNG/WebM set (referenced from each PR body) lives on the [`demo-screenshots`](https://github.com/vlussenburg/octopus-iac-lab/releases/tag/demo-screenshots) release.
