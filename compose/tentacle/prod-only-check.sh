#!/bin/bash
# Marker script — only present on the prod-pool worker. The deployment
# process's "Production gate check" step calls this; its presence + output
# is the visible proof that the step actually ran on a prod-pool worker
# rather than a dev-pool one.
set -euo pipefail

echo "[prod-only-check] this worker is bound to prod-pool"
echo "[prod-only-check] hostname: $(hostname)"
echo "[prod-only-check] timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "[prod-only-check] (if you're seeing this on a non-Production env deploy, something is wrong)"
