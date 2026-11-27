#!/usr/bin/env bash
# LiveView 1.2 (mix.lock) and LiveView 1.1 (mix.lv11.lock).
# The 1.1 line keeps deps and _build under _matrix/lv11.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "== LiveView 1.2 (mix.lock) =="
mix test

echo "== LiveView 1.1 (mix.lv11.lock) =="
SERVICERADAR_UI_LIVE_VIEW=1.1 mix deps.get
SERVICERADAR_UI_LIVE_VIEW=1.1 mix test
