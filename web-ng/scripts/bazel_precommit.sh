#!/bin/sh
set -eu

if [ -z "${HOME:-}" ]; then
  if command -v getent >/dev/null 2>&1; then
    HOST_HOME=$(getent passwd "$(id -u)" | cut -d: -f6)
  elif command -v python3 >/dev/null 2>&1; then
    HOST_HOME=$(python3 - <<'PY'
import os
import pwd
print(pwd.getpwuid(os.getuid()).pw_dir)
PY
    )
  else
    HOST_HOME="$PWD"
  fi
  export HOME="$HOST_HOME"
else
  HOST_HOME="$HOME"
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
WORK_BASE="${HOST_HOME:-$PWD}/.cache/serviceradar/bazel_precommit"
mkdir -p "$WORK_BASE"

# Persistent cache directories for deps/builds (NOT deleted between runs)
CACHE_DIR="$WORK_BASE/cache"
mkdir -p "$CACHE_DIR"

# Fresh source directory for each run (deleted on exit)
WORKDIR=$(mktemp -d -p "$WORK_BASE" src.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

# Use HTTPS instead of SSH for GitHub to avoid auth issues in CI.
# Install a git wrapper to force HTTPS on every invocation.
unset GIT_CONFIG_PARAMETERS
unset GIT_CONFIG_COUNT
for var in $(env | awk -F= '/^GIT_CONFIG_KEY_/ {print $1} /^GIT_CONFIG_VALUE_/ {print $1}'); do
  unset "$var"
done
GIT_CONFIG_GLOBAL="$WORKDIR/_gitconfig"
cat >"$GIT_CONFIG_GLOBAL" <<'EOF'
[url "https://github.com/"]
    insteadOf = git@github.com:
    insteadOf = ssh://git@github.com/
    insteadOf = git://github.com/
EOF
export GIT_CONFIG_GLOBAL
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_NOSYSTEM=1
export GIT_TERMINAL_PROMPT=0
REAL_GIT=$(command -v git || true)
if [ -n "$REAL_GIT" ]; then
  GIT_WRAP_DIR="$WORKDIR/_gitbin"
  mkdir -p "$GIT_WRAP_DIR"
  cat >"$GIT_WRAP_DIR/git" <<EOF
#!/bin/sh
set -eu
exec "$REAL_GIT" \\
  -c url.https://github.com/.insteadOf=git@github.com: \\
  -c url.https://github.com/.insteadOf=ssh://git@github.com/ \\
  -c url.https://github.com/.insteadOf=git://github.com/ \\
  "\$@"
EOF
  chmod +x "$GIT_WRAP_DIR/git"
  export PATH="$GIT_WRAP_DIR:$PATH"
  export GIT="$GIT_WRAP_DIR/git"
fi

mkdir -p "$WORKDIR/web-ng" "$WORKDIR/rust/srql" "$WORKDIR/rust/kvutil" "$WORKDIR/proto" "$WORKDIR/elixir/serviceradar_core" "$WORKDIR/elixir/datasvc"

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
copy_dir "$ROOT/elixir/serviceradar_core" "$WORKDIR/elixir/serviceradar_core"
copy_dir "$ROOT/elixir/datasvc" "$WORKDIR/elixir/datasvc"
cp "$ROOT/Cargo.toml" "$WORKDIR/Cargo.toml"
if [ -f "$ROOT/Cargo.lock" ]; then
  cp "$ROOT/Cargo.lock" "$WORKDIR/Cargo.lock"
fi

# Use persistent cache for deps/builds to avoid re-downloading/recompiling each run
export MIX_HOME="$CACHE_DIR/.mix"
export HEX_HOME="$CACHE_DIR/.hex"
export REBAR_BASE_DIR="$CACHE_DIR/.cache/rebar3"
export MIX_ENV=dev
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

TMPROOT="$WORKDIR/_tmp"
mkdir -p "$TMPROOT"
export TMPDIR="$TMPROOT"
export RUSTLER_TMPDIR="$TMPROOT"
export RUSTLER_TEMP_DIR="$TMPROOT"
# Persistent cargo target dir to cache compiled Rust deps
export CARGO_TARGET_DIR="$CACHE_DIR/_cargo_target"

cd "$WORKDIR/web-ng"

# Symlink _build and deps to persistent cache for incremental compilation
# These directories contain compiled artifacts that would be expensive to rebuild
mkdir -p "$CACHE_DIR/_build" "$CACHE_DIR/deps"
ln -sfn "$CACHE_DIR/_build" "$WORKDIR/web-ng/_build"
ln -sfn "$CACHE_DIR/deps" "$WORKDIR/web-ng/deps"

# Only install hex/rebar if not already cached
if ! ls "$MIX_HOME/archives/hex-"* >/dev/null 2>&1; then
  mix local.hex --force
fi
if [ ! -f "$MIX_HOME/rebar3" ]; then
  mix local.rebar --force
fi
if ! mix deps.get; then
  echo "mix deps.get failed; git diagnostics:" >&2
  if command -v git >/dev/null 2>&1; then
    echo "git binary: $(command -v git)" >&2
    git --version >&2 || true
  fi
  if [ -d "deps/heroicons/.git" ]; then
    git -C deps/heroicons remote -v >&2 || true
    git -C deps/heroicons config --get remote.origin.url >&2 || true
  fi
  exit 1
fi
mix precommit_lint
