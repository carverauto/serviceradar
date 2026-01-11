#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_HOME="${HOME}"

if command -v asdf >/dev/null 2>&1 && asdf exec mix --version >/dev/null 2>&1; then
  export ASDF_DIR="${ASDF_DIR:-$REAL_HOME/.asdf}"
  export ASDF_DATA_DIR="${ASDF_DATA_DIR:-$REAL_HOME/.asdf}"
  MIX_CMD=(asdf exec mix)
elif command -v mix >/dev/null 2>&1; then
  MIX_CMD=(mix)
else
  echo "mix not found (install Elixir or asdf)." >&2
  exit 1
fi

if [ "$#" -gt 0 ]; then
  PROJECTS=("$@")
else
  PROJECTS=(
    "elixir/serviceradar_core"
    "elixir/serviceradar_core_elx"
    "elixir/serviceradar_agent_gateway"
    "web-ng"
  )
fi

TMP_HOME="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_HOME"
}
trap cleanup EXIT

export HOME="$TMP_HOME"
export MIX_HOME="$HOME/.mix"
export HEX_HOME="$HOME/.hex"
export MIX_ENV=prod
export MIX_DEPS_PATH="$HOME/deps"
export MIX_BUILD_PATH="$HOME/_build"
export GIT_TERMINAL_PROMPT=0

"${MIX_CMD[@]}" local.hex --force
"${MIX_CMD[@]}" local.rebar --force

for project in "${PROJECTS[@]}"; do
  if [ ! -f "$ROOT_DIR/$project/mix.exs" ]; then
    echo "mix.exs not found in $project" >&2
    exit 1
  fi
  (cd "$ROOT_DIR/$project" && "${MIX_CMD[@]}" deps.get --only prod)
done

if [ ! -f "$HEX_HOME/cache.ets" ]; then
  echo "Hex registry cache missing at $HEX_HOME/cache.ets" >&2
  exit 1
fi

tar -C "$HOME" -czf "$ROOT_DIR/build/hex_cache.tar.gz" .hex .mix
echo "Updated $ROOT_DIR/build/hex_cache.tar.gz"
