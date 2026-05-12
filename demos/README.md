# Demo capture

`capture.js` re-runs the screenshot proofs shown in each demo PR's body. Output goes to `demos/out/` (gitignored).

## Setup (one-time)

```bash
npm i playwright
npx playwright install chromium
```

## Run

```bash
# Everything
node demos/capture.js

# Just this branch's demo
node demos/capture.js platform-hub        # PR #46
node demos/capture.js blue-green          # PR #28
node demos/capture.js octopus-native-bg   # PR #29
node demos/capture.js bg-preview          # PR #30
node demos/capture.js argo-ephemeral      # PR #25
node demos/capture.js argo-sealed-secrets # PR #26
node demos/capture.js apps                # all live-app URLs
```

## Env

| Var | Default |
|---|---|
| `OCTO_URL` | `http://localhost:8090` |
| `OCTO_USER` / `OCTO_PASS` | `admin` / `Password01!` (from `compose/docker-compose.yml`) |
| `ARGOCD_URL` | `http://argocd.localtest.me:8080` |
| `ARGOCD_USER` / `ARGOCD_PASS` | `admin` / `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d` |

The published PNG set (referenced from each PR body) lives on the [`demo-screenshots`](https://github.com/vlussenburg/octopus-iac-lab/releases/tag/demo-screenshots) release.
