#!/bin/sh
set -eu

if [ -z "${HOME:-}" ]; then
  if command -v getent >/dev/null 2>&1; then
    HOME=$(getent passwd "$(id -u)" | cut -d: -f6)
  elif command -v python3 >/dev/null 2>&1; then
    HOME=$(python3 - <<'PY'
import os
import pwd
print(pwd.getpwuid(os.getuid()).pw_dir)
PY
    )
  else
    HOME="$PWD"
  fi
  export HOME
fi

if ! command -v mix >/dev/null 2>&1; then
  echo "mix not found in PATH" >&2
  exit 1
fi

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo not found in PATH" >&2
  exit 1
fi

openssl_lib_dir="${OPENSSL_LIB_DIR:-}"
if [ -n "$openssl_lib_dir" ] && [ ! -d "$openssl_lib_dir" ]; then
  openssl_lib_dir=""
fi

if [ -z "$openssl_lib_dir" ]; then
  for dir in /usr/lib/x86_64-linux-gnu /usr/lib64 /usr/lib; do
    if [ -d "$dir" ] && ls "$dir"/libssl.so* >/dev/null 2>&1; then
      openssl_lib_dir="$dir"
      break
    fi
  done
fi

if [ -n "$openssl_lib_dir" ]; then
  export OPENSSL_LIB_DIR="$openssl_lib_dir"
fi

if [ -z "${OPENSSL_INCLUDE_DIR:-}" ] && [ -d /usr/include/openssl ]; then
  export OPENSSL_INCLUDE_DIR=/usr/include
fi

ROOT="${TEST_SRCDIR:?}/${TEST_WORKSPACE:?}"
WORK_BASE="${HOME:-$PWD}/.cache/serviceradar/bazel_precommit"
mkdir -p "$WORK_BASE"
WORKDIR=$(mktemp -d -p "$WORK_BASE")
trap 'rm -rf "$WORKDIR"' EXIT

mkdir -p "$WORKDIR/web-ng" "$WORKDIR/rust/srql" "$WORKDIR/rust/kvutil" "$WORKDIR/proto" "$WORKDIR/elixir/datasvc"

copy_dir() {
  src="$1"
  dest="$2"

  if command -v rsync >/dev/null 2>&1; then
    rsync -a "${src}/" "${dest}/"
    return
  fi

  mkdir -p "$dest"
  if command -v tar >/dev/null 2>&1; then
    (cd "$src" && tar -cf - .) | (cd "$dest" && tar -xf -)
    return
  fi

  cp -a "$src"/. "$dest"/ 2>/dev/null || cp -R "$src"/. "$dest"/
}

copy_dir "$ROOT/web-ng" "$WORKDIR/web-ng"
if [ -f "$ROOT/.tool-versions" ]; then
  cp "$ROOT/.tool-versions" "$WORKDIR/web-ng/.tool-versions"
fi
copy_dir "$ROOT/rust/srql" "$WORKDIR/rust/srql"
copy_dir "$ROOT/rust/kvutil" "$WORKDIR/rust/kvutil"
copy_dir "$ROOT/proto" "$WORKDIR/proto"
copy_dir "$ROOT/elixir/datasvc" "$WORKDIR/elixir/datasvc"
cp "$ROOT/Cargo.toml" "$WORKDIR/Cargo.toml"
if [ -f "$ROOT/Cargo.lock" ]; then
  cp "$ROOT/Cargo.lock" "$WORKDIR/Cargo.lock"
fi

export MIX_HOME="$WORKDIR/.mix"
export HEX_HOME="$WORKDIR/.hex"
export REBAR_BASE_DIR="$WORKDIR/.cache/rebar3"
export MIX_ENV=test
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

TMPROOT="$WORKDIR/_tmp"
mkdir -p "$TMPROOT"
export TMPDIR="$TMPROOT"
export RUSTLER_TMPDIR="$TMPROOT"
export RUSTLER_TEMP_DIR="$TMPROOT"
export CARGO_TARGET_DIR="$WORKDIR/_cargo_target"

cd "$WORKDIR/web-ng"
mix local.hex --force
mix local.rebar --force
mix deps.get
mix ecto.create
mix precommit
