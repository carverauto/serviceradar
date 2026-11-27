#!/usr/bin/env bash
# Format, warnings-as-errors, Credo, both LiveView lines, hook bundle, example app.
set -euo pipefail

cd "$(dirname "$0")/.."

mix format --check-formatted
mix compile --warnings-as-errors
MIX_ENV=prod mix compile --warnings-as-errors
mix credo --strict

(
  cd assets
  node --test js/test/
  node scripts/build.mjs --check
  node scripts/bundle_size.mjs
)

./scripts/test_matrix.sh

(
  cd example
  mix deps.get
  mix format --check-formatted
  mix test
)
