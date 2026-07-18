#!/usr/bin/env bash
# Swap B: take the Node CopilotKit runtime out of the path entirely.
# Parks the Next API route (app routes beat rewrites) so the
# RUBY_RUNTIME_URL rewrite in next.config.ts serves the whole
# /api/copilotkit surface from the Ruby server.
#
#   scripts/swap-b.sh          # park the Node runtime route
#   scripts/swap-b.sh --undo   # restore it (back to Swap A)
#
# Then: RUBY_RUNTIME_URL=http://127.0.0.1:9292 npm run dev:ui
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${1:-}" == "--undo" ]]; then
  [[ -d src/app/_api_node_runtime ]] && mv src/app/_api_node_runtime src/app/api
  echo "swap A restored: Node runtime route back at src/app/api"
else
  [[ -d src/app/api ]] && mv src/app/api src/app/_api_node_runtime
  echo "swap B armed: Node runtime route parked; set RUBY_RUNTIME_URL and restart dev:ui"
fi
