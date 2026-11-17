#!/usr/bin/env bash
# Builds the app bundle and relaunches it on mock data instead of real provider APIs.
# Adjust the data from the popover's ⋯ menu → "Mock Data…" window; changes apply immediately.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

"$ROOT_DIR/scripts/bundle-app.sh"
pkill -x AgentQuotaBar || true
open -n "$ROOT_DIR/dist/AgentQuotaBar.app" --args --mock-data
echo "Running on mock data"
