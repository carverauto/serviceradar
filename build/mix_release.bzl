"""Lightweight rule to run `mix release` hermetically using rules_elixir toolchains."""

def _mix_release_impl(ctx):
    toolchain = ctx.toolchains["@rules_elixir//:toolchain_type"]
    rust_toolchain = ctx.toolchains["@rules_rust//rust:toolchain"]

    otp = toolchain.otpinfo
    elixir = toolchain.elixirinfo
    cargo = rust_toolchain.cargo
    rustc = rust_toolchain.rustc

    erlang_home = otp.erlang_home
    otp_tar = getattr(otp, "release_dir_tar", None)
    # Use short_path for tree artifacts so the symlink forest in the sandbox
    # can find the binaries reliably.
    elixir_home = elixir.elixir_home or elixir.release_dir.short_path

    tar_out = ctx.outputs.out

    toolchain_inputs = [
        otp.version_file,
        elixir.version_file,
        cargo,
        rustc,
    ]
    if getattr(otp, "release_dir_tar", None):
        toolchain_inputs.append(otp.release_dir_tar)
    if getattr(elixir, "release_dir", None):
        toolchain_inputs.append(elixir.release_dir)

    transitive_inputs = []
    if getattr(rust_toolchain, "rustc_lib", None):
        # rustc depends on its own shared libraries (e.g. librustc_driver); make
        # sure they are available to the action sandbox, especially on remote
        # executors where runfiles are not automatically present.
        transitive_inputs.append(rust_toolchain.rustc_lib)
    if getattr(rust_toolchain, "rust_std", None):
        # Provide the Rust stdlib for the host/exec toolchain so cargo can find
        # the core/std crates when compiling NIFs on remote Linux builders.
        transitive_inputs.append(rust_toolchain.rust_std)

    hex_cache = ctx.file.hex_cache
    direct_inputs = toolchain_inputs + ctx.files.srcs + ctx.files.data + ctx.files.extra_dir_srcs
    if hex_cache:
        direct_inputs.append(hex_cache)

    inputs = depset(
        direct = direct_inputs,
        transitive = transitive_inputs,
    )

    extra_copy_cmds = []
    for d in ctx.attr.extra_dirs:
        parent = d.rpartition("/")[0] or "."
        extra_copy_cmds.append(
            'mkdir -p "$WORKDIR/{parent}"\ncopy_dir "$EXECROOT/{dir}/" "$WORKDIR/{dir}/"\n'.format(
                dir = d,
                parent = parent,
            ),
        )

    run_assets = "true" if ctx.attr.run_assets else "false"

    ctx.actions.run_shell(
        mnemonic = "MixRelease",
        inputs = inputs,
        outputs = [tar_out],
        progress_message = "mix release ({})".format(ctx.label.name),
command = """
set -euo pipefail

EXECROOT=$PWD

ELIXIR_HOME_RAW="{elixir_home}"
ELIXIR_HOME=$(cd "$EXECROOT" && cd "$ELIXIR_HOME_RAW" && pwd)

if [ -n "{otp_tar}" ] && [ -f "{otp_tar}" ]; then
  OTP_ROOT=$(mktemp -d)
  tar -xf "{otp_tar}" -C "$OTP_ROOT"
  if [ -d "$OTP_ROOT/lib/erlang" ]; then
    ERLANG_HOME="$OTP_ROOT/lib/erlang"
  else
    ERLANG_HOME=$(find "$OTP_ROOT" -maxdepth 2 -type d -name erlang -print | head -n1 | xargs dirname)
  fi
else
  ERLANG_HOME="{erlang_home}"
fi
echo "OTP_TAR={otp_tar}"
echo "ERLANG_HOME=$ERLANG_HOME"

WORKDIR=$(mktemp -d)
export HOME="$WORKDIR/.mix_home"
export MIX_HOME="$HOME/.mix"
export HEX_HOME="$HOME/.hex"
export REBAR_BASE_DIR="$HOME/.cache/rebar3"
export MIX_ENV=prod
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export ELIXIR_ERL_OPTIONS="+fnu"
export CARGO="$EXECROOT/{cargo_path}"
export RUSTC="$EXECROOT/{rustc_path}"
export PATH="$(dirname "$CARGO"):$(dirname "$RUSTC"):/opt/homebrew/bin:$ELIXIR_HOME/bin:$ERLANG_HOME/bin:$PATH"
RUST_LIB_ROOT="$(cd "$(dirname "$RUSTC")/.." && pwd)"
export LD_LIBRARY_PATH="$RUST_LIB_ROOT/lib:$RUST_LIB_ROOT/lib/rustlib/x86_64-unknown-linux-gnu/lib:${{LD_LIBRARY_PATH:-}}"
echo "PATH=$PATH"
ls -la "$ELIXIR_HOME/bin" || true
which mix || true

copy_dir() {{
  local src="$1"
  local dest="$2"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a "$src" "$dest"
  else
    mkdir -p "$dest"
    cp -a "${{src%/}}/." "$dest"
  fi
}}

if [ ! -x "$ERLANG_HOME/bin/erl" ]; then
  echo "Erlang not found under $ERLANG_HOME"
  ls -la "$ERLANG_HOME" || true
fi

mkdir -p "$HOME"
export CARGO_TARGET_DIR="$WORKDIR/_cargo_target"
TMPROOT="$WORKDIR/_tmp"
SYS_TMP=$(python3 - <<'PY'
import tempfile
print(tempfile.gettempdir())
PY
)
mkdir -p "$TMPROOT"
export TMPDIR="$TMPROOT"
export RUSTLER_TMPDIR="$TMPROOT"
export RUSTLER_TEMP_DIR="$TMPROOT"
if [ -n "{hex_cache_tar}" ] && [ -f "$EXECROOT/{hex_cache_tar}" ]; then
  case "$EXECROOT/{hex_cache_tar}" in
    *.tar.gz|*.tgz) tar -xzf "$EXECROOT/{hex_cache_tar}" -C "$HOME" ;;
    *) tar -xf "$EXECROOT/{hex_cache_tar}" -C "$HOME" ;;
  esac
  # NOTE: We intentionally do NOT set HEX_OFFLINE=1 here.
  # The hex_cache is an optimization to pre-seed packages, but if any
  # packages are missing or outdated, Mix should be allowed to fetch them.
  # This avoids the need to manually regenerate hex_cache.tar.gz every time
  # dependencies change.
fi
if [ -d /cache ] && [ -w /cache ]; then
  export CARGO_HOME="/cache/cargo"
else
  export CARGO_HOME="$HOME/.cargo"
fi
mkdir -p "$CARGO_HOME"
copy_dir "{src_dir}/" "$WORKDIR/"
{extra_copy}
if [ -f "$EXECROOT/Cargo.toml" ]; then
  cp "$EXECROOT/Cargo.toml" "$WORKDIR/Cargo.toml"
  [ -f "$EXECROOT/Cargo.lock" ] && cp "$EXECROOT/Cargo.lock" "$WORKDIR/Cargo.lock"

  if [ -d "$EXECROOT/rust/srql" ]; then
    mkdir -p "$WORKDIR/rust/srql"
    copy_dir "$EXECROOT/rust/srql/" "$WORKDIR/rust/srql/"
  fi
  if [ -d "$EXECROOT/rust/kvutil" ]; then
    mkdir -p "$WORKDIR/rust/kvutil"
    copy_dir "$EXECROOT/rust/kvutil/" "$WORKDIR/rust/kvutil/"
  fi
  if [ -d "$EXECROOT/proto" ]; then
    mkdir -p "$TMPROOT/rust/kvutil/proto"
    copy_dir "$EXECROOT/proto/" "$TMPROOT/rust/kvutil/proto/"
    mkdir -p "$SYS_TMP/rust/kvutil/proto"
    copy_dir "$EXECROOT/proto/" "$SYS_TMP/rust/kvutil/proto/"
  fi

  if [ -d "$WORKDIR/rust" ]; then
    mkdir -p /tmp/rust
    rm -rf /tmp/rust/srql /tmp/rust/kvutil
    [ -d "$WORKDIR/rust/srql" ] && ln -s "$WORKDIR/rust/srql" /tmp/rust/srql
    [ -d "$WORKDIR/rust/kvutil" ] && ln -s "$WORKDIR/rust/kvutil" /tmp/rust/kvutil
    cat > /tmp/rust/Cargo.toml <<'EOF'
[workspace]
resolver = "2"
members = ["srql", "kvutil"]

[workspace.dependencies]
tonic = {{ version = "0.12", features = ["tls"] }}
prost = "0.13"
tonic-build = "0.12"
tokio = {{ version = "1" }}
tokio-stream = "0.1"
tonic-health = "0.12"
tonic-reflection = "0.12"

[profile.release]
opt-level = 3
debug = false
rpath = false
lto = true
debug-assertions = false
panic = "abort"
EOF
  fi
fi

mkdir -p /tmp/elixir
rm -rf /tmp/elixir/datasvc
ln -s "$WORKDIR/elixir/datasvc" /tmp/elixir/datasvc
rm -rf /tmp/elixir/serviceradar_core
ln -s "$WORKDIR/elixir/serviceradar_core" /tmp/elixir/serviceradar_core
rm -rf /tmp/serviceradar_core
ln -s "$WORKDIR/elixir/serviceradar_core" /tmp/serviceradar_core

cd "$WORKDIR"
chmod -R u+w .

# Fetch and compile deps, build assets, create release into Bazel output dir
if ! ls "$MIX_HOME/archives/hex-"* >/dev/null 2>&1; then
  mix local.hex --force
fi
if [ -x "$MIX_HOME/rebar3" ]; then
  export MIX_REBAR3="$MIX_HOME/rebar3"
elif ls "$MIX_HOME/elixir"/*/rebar3 >/dev/null 2>&1; then
  export MIX_REBAR3=$(ls "$MIX_HOME/elixir"/*/rebar3 | head -n 1)
fi
if [ -z "${{MIX_REBAR3:-}}" ]; then
  mix local.rebar --force
fi
mix deps.get --only prod
mix deps.compile
if [ "{run_assets}" = "true" ]; then
  # Preserve existing static assets (favicon, images, robots.txt) before clearing priv/static
  PRESERVED_STATIC=$(mktemp -d)
  if [ -d priv/static ]; then
    [ -f priv/static/favicon.ico ] && cp priv/static/favicon.ico "$PRESERVED_STATIC/"
    [ -f priv/static/robots.txt ] && cp priv/static/robots.txt "$PRESERVED_STATIC/"
    [ -d priv/static/images ] && cp -r priv/static/images "$PRESERVED_STATIC/"
  fi

  STATIC_ROOT="$WORKDIR/priv_static"
  DIGEST_ROOT="$WORKDIR/priv_static_digest"
  rm -rf priv/static "$DIGEST_ROOT"
  mkdir -p "$STATIC_ROOT/assets/css"
  ln -s "$STATIC_ROOT" priv/static
  : > priv/static/assets/css/app.css

  # Restore preserved static assets to the symlinked directory
  [ -f "$PRESERVED_STATIC/favicon.ico" ] && cp "$PRESERVED_STATIC/favicon.ico" priv/static/
  [ -f "$PRESERVED_STATIC/robots.txt" ] && cp "$PRESERVED_STATIC/robots.txt" priv/static/
  [ -d "$PRESERVED_STATIC/images" ] && cp -r "$PRESERVED_STATIC/images" priv/static/

  TAILWIND_INPUT=assets/css/app.css \
  TAILWIND_OUTPUT=priv/static/assets/css/app.css \
  mix tailwind serviceradar_web_ng --minify
  mix esbuild serviceradar_web_ng --minify
  mix phx.digest priv/static -o "$DIGEST_ROOT"
  rm priv/static
  mv "$DIGEST_ROOT" priv/static
fi
RELEASE_DIR=$(mktemp -d)
mix release --path "$RELEASE_DIR"

# Package release to tar output (ensure parent exists, write via absolute path)
mkdir -p "$(dirname "$EXECROOT/{tar_out}")"
tar -czf "$EXECROOT/{tar_out}" -C "$RELEASE_DIR" .
""".format(
            elixir_home = elixir_home,
            erlang_home = erlang_home,
            src_dir = ctx.attr.src_dir,
            tar_out = tar_out.path,
            cargo_path = cargo.path,
            rustc_path = rustc.path,
            cargo_dir = cargo.dirname,
            rustc_dir = rustc.dirname,
            otp_tar = otp_tar.path if otp_tar else "",
            extra_copy = "".join(extra_copy_cmds),
            run_assets = run_assets,
            hex_cache_tar = hex_cache.path if hex_cache else "",
        ),
        use_default_shell_env = False,
    )

    return [
        DefaultInfo(
            files = depset([tar_out]),
        ),
    ]

mix_release = rule(
    implementation = _mix_release_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = True, doc = "Web-NG sources"),
        "data": attr.label_list(allow_files = True, doc = "Additional data files (e.g., priv/static)"),
        "src_dir": attr.string(default = "web-ng", doc = "Path to the web-ng project root relative to workspace"),
        "out": attr.output(mandatory = True),
        "run_assets": attr.bool(default = True, doc = "Whether to run assets.deploy steps"),
        "extra_dirs": attr.string_list(doc = "Workspace-relative directories to copy into the build workspace"),
        "extra_dir_srcs": attr.label_list(allow_files = True, doc = "File inputs that back extra_dirs"),
        "hex_cache": attr.label(allow_single_file = True, doc = "Tarball containing offline Hex/Mix cache"),
    },
    toolchains = [
        "@rules_elixir//:toolchain_type",
        "@rules_rust//rust:toolchain",
    ],
)
