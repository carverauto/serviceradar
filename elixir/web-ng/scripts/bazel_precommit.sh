#!/bin/sh
set -eu

unset ENV
unset BASH_ENV

HOST_HOME="${HOME:-}"
if command -v getent >/dev/null 2>&1; then
  resolved_home=$(getent passwd "$(id -u)" | cut -d: -f6)
  if [ -n "${resolved_home:-}" ]; then
    HOST_HOME="$resolved_home"
  fi
elif command -v python3 >/dev/null 2>&1; then
  resolved_home=$(python3 - <<'PY'
import os
import pwd
print(pwd.getpwuid(os.getuid()).pw_dir)
PY
  )
  if [ -n "${resolved_home:-}" ]; then
    HOST_HOME="$resolved_home"
  fi
fi

if [ -z "$HOST_HOME" ]; then
  HOST_HOME="$PWD"
fi
export HOME="$HOST_HOME"

if ! command -v mix >/dev/null 2>&1; then
  echo "mix not found in PATH" >&2
  exit 1
fi

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo not found in PATH" >&2
  exit 1
fi

openssl_dir="${OPENSSL_DIR:-}"
openssl_lib_dir="${OPENSSL_LIB_DIR:-}"
openssl_include_dir="${OPENSSL_INCLUDE_DIR:-}"
uname_s="$(uname -s)"

if [ -n "$openssl_dir" ] && [ ! -d "$openssl_dir" ]; then
  openssl_dir=""
fi

if [ -n "$openssl_lib_dir" ] && [ ! -d "$openssl_lib_dir" ]; then
  openssl_lib_dir=""
fi

if [ -n "$openssl_include_dir" ] && [ ! -d "$openssl_include_dir" ]; then
  openssl_include_dir=""
fi

if [ "$uname_s" = "Darwin" ]; then
  for candidate in \
    /opt/homebrew/opt/openssl@3 \
    /usr/local/opt/openssl@3 \
    /opt/homebrew/opt/openssl \
    /usr/local/opt/openssl
  do
    if [ -d "$candidate/lib" ] && [ -d "$candidate/include" ]; then
      openssl_dir="$candidate"
      openssl_lib_dir="$candidate/lib"
      openssl_include_dir="$candidate/include"
      break
    fi
  done
else
  if [ -z "$openssl_dir" ] && [ -d /usr ]; then
    openssl_dir=/usr
  fi

  if [ -z "$openssl_lib_dir" ]; then
    for dir in /usr/lib/x86_64-linux-gnu /usr/lib64 /usr/lib; do
      if [ -d "$dir" ] && ls "$dir"/libssl.so* >/dev/null 2>&1; then
        openssl_lib_dir="$dir"
        break
      fi
    done
  fi

  if [ -z "$openssl_include_dir" ] && [ -d /usr/include/openssl ]; then
    openssl_include_dir=/usr/include
  fi
fi

if [ -n "$openssl_dir" ]; then
  export OPENSSL_DIR="$openssl_dir"
else
  unset OPENSSL_DIR
fi

if [ -n "$openssl_lib_dir" ]; then
  export OPENSSL_LIB_DIR="$openssl_lib_dir"
else
  unset OPENSSL_LIB_DIR
fi

if [ -n "$openssl_include_dir" ]; then
  export OPENSSL_INCLUDE_DIR="$openssl_include_dir"
else
  unset OPENSSL_INCLUDE_DIR
fi

openssl_pkgconfig_dir=""
if [ -n "${OPENSSL_DIR:-}" ] && [ -d "${OPENSSL_DIR}/lib/pkgconfig" ]; then
  openssl_pkgconfig_dir="${OPENSSL_DIR}/lib/pkgconfig"
elif [ -n "${OPENSSL_LIB_DIR:-}" ] && [ -d "${OPENSSL_LIB_DIR}/pkgconfig" ]; then
  openssl_pkgconfig_dir="${OPENSSL_LIB_DIR}/pkgconfig"
fi

if [ -n "$openssl_pkgconfig_dir" ]; then
  case ":${PKG_CONFIG_PATH:-}:" in
    *:"$openssl_pkgconfig_dir":*) ;;
    *)
      if [ -n "${PKG_CONFIG_PATH:-}" ]; then
        export PKG_CONFIG_PATH="$openssl_pkgconfig_dir:$PKG_CONFIG_PATH"
      else
        export PKG_CONFIG_PATH="$openssl_pkgconfig_dir"
      fi
      ;;
  esac
fi

# Hex can time out in CI when a precommit run needs to fetch a large dependency
# graph from scratch. Bias toward reliability in Bazel precommit runs.
export HEX_HTTP_CONCURRENCY="${HEX_HTTP_CONCURRENCY:-1}"
export HEX_HTTP_TIMEOUT="${HEX_HTTP_TIMEOUT:-120}"

ROOT="${TEST_SRCDIR:?}/${TEST_WORKSPACE:?}"
WEB_NG_SRC="${ROOT}/elixir/web-ng"

WORK_BASE="${HOST_HOME:-$PWD}/.cache/serviceradar/bazel_precommit"
mkdir -p "$WORK_BASE"

# Persistent cache directories for deps/builds (NOT deleted between runs)
CACHE_DIR="$WORK_BASE/cache"
mkdir -p "$CACHE_DIR"

# Use consistent source directory name for path caching compatibility
# The _build directory caches absolute paths, so we need stable paths across runs
WORKDIR="$WORK_BASE/src"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
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

mkdir -p "$WORKDIR/elixir" "$WORKDIR/elixir/web-ng" "$WORKDIR/rust/srql" "$WORKDIR/rust/kvutil" "$WORKDIR/proto" "$WORKDIR/elixir/connection" "$WORKDIR/elixir/elixir_uuid" "$WORKDIR/elixir/serviceradar_core" "$WORKDIR/elixir/serviceradar_srql" "$WORKDIR/elixir/datasvc" "$WORKDIR/elixir/vendor/opentelemetry_oban"

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

copy_dir "$WEB_NG_SRC" "$WORKDIR/elixir/web-ng"
if [ -f "$ROOT/.tool-versions" ]; then
  cp "$ROOT/.tool-versions" "$WORKDIR/elixir/web-ng/.tool-versions"
fi
for shared_credo in .credo.base.exs .credo.ex_dna.exs .credo.jump_checks.exs .credo.ex_slop.exs; do
  if [ -f "$ROOT/elixir/$shared_credo" ]; then
    cp "$ROOT/elixir/$shared_credo" "$WORKDIR/elixir/$shared_credo"
  fi
done
copy_dir "$ROOT/rust/srql" "$WORKDIR/rust/srql"
copy_dir "$ROOT/rust/kvutil" "$WORKDIR/rust/kvutil"
copy_dir "$ROOT/proto" "$WORKDIR/proto"
copy_dir "$ROOT/elixir/connection" "$WORKDIR/elixir/connection"
copy_dir "$ROOT/elixir/elixir_uuid" "$WORKDIR/elixir/elixir_uuid"
copy_dir "$ROOT/elixir/serviceradar_core" "$WORKDIR/elixir/serviceradar_core"
copy_dir "$ROOT/elixir/serviceradar_srql" "$WORKDIR/elixir/serviceradar_srql"
copy_dir "$ROOT/elixir/datasvc" "$WORKDIR/elixir/datasvc"
copy_dir "$ROOT/elixir/vendor/opentelemetry_oban" "$WORKDIR/elixir/vendor/opentelemetry_oban"
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

cd "$WORKDIR/elixir/web-ng"

deps_cache_key() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@" | sha256sum | awk '{print $1}'
    return
  fi

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$@" | shasum -a 256 | awk '{print $1}'
    return
  fi

  cksum "$@" | cksum | awk '{print $1}'
}

set -- \
  mix.exs \
  mix.lock \
  ../connection/mix.exs \
  ../serviceradar_core/mix.exs \
  ../serviceradar_srql/mix.exs \
  ../datasvc/mix.exs \
  ../vendor/opentelemetry_oban/mix.exs

for maybe_lock in \
  ../connection/mix.lock \
  ../serviceradar_core/mix.lock \
  ../serviceradar_srql/mix.lock \
  ../datasvc/mix.lock \
  ../vendor/opentelemetry_oban/mix.lock
do
  if [ -f "$maybe_lock" ]; then
    set -- "$@" "$maybe_lock"
  fi
done

DEPS_CACHE_FINGERPRINT="$(deps_cache_key "$@")"
DEPS_CACHE_KEY_FILE="$CACHE_DIR/deps.key"

if [ -f "$DEPS_CACHE_KEY_FILE" ] && [ "$(cat "$DEPS_CACHE_KEY_FILE")" != "$DEPS_CACHE_FINGERPRINT" ]; then
  rm -rf "$CACHE_DIR/deps" "$CACHE_DIR/_build"
fi

# Restore cached deps if available (speeds up mix deps.get significantly)
# This avoids re-cloning heroicons and re-downloading hex packages each run
if [ -d "$CACHE_DIR/deps" ]; then
  cp -a "$CACHE_DIR/deps" "$WORKDIR/elixir/web-ng/deps"
fi

clean_dependency_cache() {
  rm -rf \
    "$CACHE_DIR/deps" \
    "$CACHE_DIR/_build" \
    "$WORKDIR/elixir/web-ng/deps" \
    "$WORKDIR/elixir/web-ng/_build"
}

# Only install hex/rebar if not already cached
if ! ls "$MIX_HOME/archives/hex-"* >/dev/null 2>&1; then
  mix local.hex --force
fi
if [ ! -f "$MIX_HOME/rebar3" ]; then
  mix local.rebar --force
fi
deps_get_ok=0
for attempt in 1 2 3; do
  if mix deps.get; then
    deps_get_ok=1
    break
  fi

  if [ "$attempt" -eq 1 ]; then
    clean_dependency_cache
  fi

  if [ "$attempt" -lt 3 ]; then
    sleep $((attempt * 5))
  fi
done

if [ "$deps_get_ok" -ne 1 ]; then
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

# Apply the same dependency warning fixes used by release builds so CI doesn't
# fail on known Elixir 1.19 typing warnings in third-party deps.
if command -v python3 >/dev/null 2>&1; then
  python3 "$ROOT/build/mix_release_patches.py" "$WORKDIR/elixir/web-ng"
fi

# Cache deps for next run (speeds up heroicons clone and hex downloads)
rm -rf "$CACHE_DIR/deps"
cp -a "$WORKDIR/elixir/web-ng/deps" "$CACHE_DIR/deps"
printf '%s\n' "$DEPS_CACHE_FINGERPRINT" >"$DEPS_CACHE_KEY_FILE"

# Restore cached _build if available (speeds up compilation)
if [ -d "$CACHE_DIR/_build" ]; then
  cp -a "$CACHE_DIR/_build" "$WORKDIR/elixir/web-ng/_build"
fi

mix precommit_fast

# Cache _build for next run
rm -rf "$CACHE_DIR/_build"
cp -a "$WORKDIR/elixir/web-ng/_build" "$CACHE_DIR/_build"
