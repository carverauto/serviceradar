"""Run the web-ng precommit checks hermetically using rules_elixir/rules_rust toolchains.

This exists to replace a host-toolchain escape hatch. The previous implementation was an
`sh_test` tagged `local`/`no-remote`/`no-sandbox` whose script began with

    command -v mix   || exit 1
    command -v cargo || exit 1

so it could only ever run where somebody had installed Elixir and Rust by hand. That is why
it could not go to the executors: the RBE image is `FROM ubuntu:24.04` with no Erlang, no
Elixir, and no cargo -- deliberately, because Bazel provides those toolchains.

So this rule takes them from Bazel, exactly as //build:mix_release.bzl already does for the
production release: OTP and Elixir from `@rules_elixir//:toolchain_type`, cargo and rustc
from `@rules_rust//rust:toolchain`, all declared as action inputs. Nothing is read from
$PATH that Bazel did not put there.

Two consequences worth understanding:

  * It is a build ACTION producing a log, not a test. That is what makes it remotely
    cacheable -- an unchanged tree is a cache hit rather than a rebuild. //elixir/web-ng
    wraps it in a skylib `build_test` so `bazel test //elixir/web-ng:precommit` still works.

  * There is no ${HOST_HOME}/.cache work directory. The old script kept deps/_build/cargo
    target outside the execroot and hand-rolled its own cache, which is precisely what
    forced `no-sandbox`. Bazel's own action cache replaces it.

`mix deps.get` still needs network egress. That is not new -- mix_release does the same --
and the executors run with dockerNetwork: host. The optional `hex_cache` attr pre-seeds the
Hex cache the same way mix_release uses it.
"""

def _mix_precommit_impl(ctx):
    toolchain = ctx.toolchains["@rules_elixir//:toolchain_type"]
    rust_toolchain = ctx.toolchains["@rules_rust//rust:toolchain"]

    otp = toolchain.otpinfo
    elixir = toolchain.elixirinfo
    cargo = rust_toolchain.cargo
    rustc = rust_toolchain.rustc
    workspace_cargo_toml = ctx.file.workspace_cargo_toml
    hex_cache = ctx.file.hex_cache
    patches = ctx.file.patches

    erlang_home = otp.erlang_home
    otp_tar = getattr(otp, "release_dir_tar", None)

    # short_path for tree artifacts, so the sandbox symlink forest resolves the binaries.
    elixir_home = elixir.elixir_home or elixir.release_dir.short_path

    log_out = ctx.outputs.out

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
        # rustc needs its own shared libraries (librustc_driver et al). Remote executors do
        # not stage runfiles automatically, so these have to be declared.
        transitive_inputs.append(rust_toolchain.rustc_lib)
    if getattr(rust_toolchain, "rust_std", None):
        # The Rust stdlib for the exec toolchain, so cargo can find core/std when it builds
        # the Rustler NIFs on a remote Linux builder.
        transitive_inputs.append(rust_toolchain.rust_std)

    direct_inputs = (
        toolchain_inputs +
        ctx.files.srcs +
        ctx.files.data +
        ctx.files.extra_dir_srcs +
        [workspace_cargo_toml]
    )
    if hex_cache:
        direct_inputs.append(hex_cache)
    if patches:
        direct_inputs.append(patches)

    inputs = depset(direct = direct_inputs, transitive = transitive_inputs)

    extra_copy_cmds = []
    for d in ctx.attr.extra_dirs:
        parent = d.rpartition("/")[0] or "."
        extra_copy_cmds.append(
            'mkdir -p "$WORKDIR/{parent}"\ncopy_dir "$EXECROOT/{dir}/" "$WORKDIR/{dir}/"\n'.format(
                dir = d,
                parent = parent,
            ),
        )

    ctx.actions.run_shell(
        mnemonic = "MixPrecommit",
        inputs = inputs,
        outputs = [log_out],
        progress_message = "mix precommit ({})".format(ctx.label.name),
        command = """
set -euo pipefail

EXECROOT=$PWD
LOG="$EXECROOT/{log_out}"
mkdir -p "$(dirname "$LOG")"

# Everything below goes to the log as well as the console, so a remote failure is
# explicable from the cached output alone.
exec > >(tee "$LOG") 2>&1

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

WORKDIR=$(mktemp -d)
CACHE_ROOT=$(mktemp -d)

export HOME="$CACHE_ROOT/home"
export MIX_HOME="$HOME/.mix"
export HEX_HOME="$HOME/.hex"
export REBAR_BASE_DIR="$HOME/.cache/rebar3"
export MIX_ENV=test
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export ELIXIR_ERL_OPTIONS="+fnu"
export HEX_HTTP_CONCURRENCY="${{HEX_HTTP_CONCURRENCY:-1}}"
export HEX_HTTP_TIMEOUT="${{HEX_HTTP_TIMEOUT:-120}}"
mkdir -p "$HOME"

# The toolchains, and nothing from the host. If mix or cargo is missing after this, the
# toolchain is wrong -- which is a build error worth seeing, not a reason to fall back.
export CARGO="$EXECROOT/{cargo_path}"
export RUSTC="$EXECROOT/{rustc_path}"
export PATH="$(dirname "$CARGO"):$(dirname "$RUSTC"):$ELIXIR_HOME/bin:$ERLANG_HOME/bin:$PATH"

RUST_LIB_ROOT="$(cd "$(dirname "$RUSTC")/.." && pwd)"
export LD_LIBRARY_PATH="$RUST_LIB_ROOT/lib:$RUST_LIB_ROOT/lib/rustlib/x86_64-unknown-linux-gnu/lib:${{LD_LIBRARY_PATH:-}}"

export CARGO_HOME="$CACHE_ROOT/cargo"
export CARGO_TARGET_DIR="$CACHE_ROOT/cargo_target"
TMPROOT="$WORKDIR/_tmp"
mkdir -p "$TMPROOT" "$CARGO_HOME" "$CARGO_TARGET_DIR"
export TMPDIR="$TMPROOT"
export RUSTLER_TMPDIR="$TMPROOT"
export RUSTLER_TEMP_DIR="$TMPROOT"

echo "ERLANG_HOME=$ERLANG_HOME"
echo "ELIXIR_HOME=$ELIXIR_HOME"
command -v mix
command -v cargo

copy_dir() {{
  local src="$1"
  local dest="$2"
  # rsync creates only the final path component, so a nested destination such as
  # $WORKDIR/elixir/web-ng fails with ENOENT unless the parents already exist.
  mkdir -p "$dest"
  local -a excludes=(
    "--exclude=.git"
    "--exclude=.elixir_ls"
    "--exclude=_build"
    "--exclude=deps"
    "--exclude=node_modules"
    "--exclude=target"
    "--exclude=erl_crash.dump"
    "--exclude=tmp"
  )
  if command -v rsync >/dev/null 2>&1; then
    # Bazel stages sources as symlinks; dereference so Mix writes stay in WORKDIR.
    rsync -aL "${{excludes[@]}}" "$src" "$dest"
  else
    mkdir -p "$dest"
    tar -C "${{src%/}}" -cf - "${{excludes[@]}}" . | tar -C "$dest" -xf -
  fi
}}

copy_dir "{src_dir}/" "$WORKDIR/{src_dir}/"
{extra_copy}
if [ -f "$EXECROOT/{workspace_cargo_toml}" ]; then
  cp "$EXECROOT/{workspace_cargo_toml}" "$WORKDIR/Cargo.toml"
fi

if [ -n "{hex_cache_tar}" ] && [ -f "$EXECROOT/{hex_cache_tar}" ]; then
  case "$EXECROOT/{hex_cache_tar}" in
    *.tar.gz|*.tgz) tar -xzf "$EXECROOT/{hex_cache_tar}" -C "$HOME" ;;
    *) tar -xf "$EXECROOT/{hex_cache_tar}" -C "$HOME" ;;
  esac
fi

cd "$WORKDIR/{src_dir}"
chmod -R u+w .

if ! ls "$MIX_HOME/archives/hex-"* >/dev/null 2>&1; then
  mix local.hex --force
fi
if [ ! -f "$MIX_HOME/rebar3" ]; then
  mix local.rebar --force
fi

mix deps.get

# The same third-party warning fixes the release build applies, so precommit does not fail
# on known Elixir 1.19 typing warnings in deps.
if [ -n "{patches}" ] && [ -f "$EXECROOT/{patches}" ]; then
  python3 "$EXECROOT/{patches}" "$WORKDIR/{src_dir}"
fi

mix {mix_task}
""".format(
            log_out = log_out.path,
            elixir_home = elixir_home,
            erlang_home = erlang_home,
            otp_tar = otp_tar.path if otp_tar else "",
            cargo_path = cargo.path,
            rustc_path = rustc.path,
            src_dir = ctx.attr.src_dir,
            extra_copy = "".join(extra_copy_cmds),
            workspace_cargo_toml = workspace_cargo_toml.short_path,
            hex_cache_tar = hex_cache.path if hex_cache else "",
            patches = patches.path if patches else "",
            mix_task = ctx.attr.mix_task,
        ),
        use_default_shell_env = False,
    )

    return [DefaultInfo(files = depset([log_out]))]

mix_precommit = rule(
    implementation = _mix_precommit_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = True, doc = "Project sources"),
        "data": attr.label_list(allow_files = True, doc = "Additional data files"),
        "src_dir": attr.string(
            mandatory = True,
            doc = "Workspace-relative path to the Mix project root",
        ),
        "extra_dirs": attr.string_list(
            doc = "Workspace-relative directories to stage alongside the project (path deps)",
        ),
        "extra_dir_srcs": attr.label_list(
            allow_files = True,
            doc = "File inputs backing extra_dirs",
        ),
        "mix_task": attr.string(
            default = "precommit_fast",
            doc = "Mix task to run once dependencies are in place",
        ),
        "hex_cache": attr.label(
            allow_single_file = True,
            doc = "Optional tarball pre-seeding the Hex/Mix cache",
        ),
        "patches": attr.label(
            allow_single_file = True,
            doc = "Optional python script applying third-party dependency patches",
        ),
        "workspace_cargo_toml": attr.label(
            allow_single_file = True,
            default = Label("//:Cargo.toml"),
            doc = "Root Cargo workspace manifest used by the Rustler path dependencies",
        ),
        "out": attr.output(mandatory = True, doc = "Log file produced by the run"),
    },
    toolchains = [
        "@rules_elixir//:toolchain_type",
        "@rules_rust//rust:toolchain",
    ],
)
