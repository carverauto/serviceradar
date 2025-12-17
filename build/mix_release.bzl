"""Lightweight rule to run `mix release` hermetically using rules_elixir toolchains."""

def _mix_release_impl(ctx):
    toolchain = ctx.toolchains["@rules_elixir//:toolchain_type"]
    rust_toolchain = ctx.toolchains["@rules_rust//rust:toolchain"]

    otp = toolchain.otpinfo
    elixir = toolchain.elixirinfo
    cargo = rust_toolchain.cargo
    rustc = rust_toolchain.rustc

    erlang_home = otp.erlang_home
    elixir_home = elixir.elixir_home or elixir.release_dir.path

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

    inputs = depset(toolchain_inputs + ctx.files.srcs + ctx.files.data + ctx.files.extra_dir_srcs)

    extra_copy_cmds = []
    for d in ctx.attr.extra_dirs:
        parent = d.rpartition("/")[0] or "."
        extra_copy_cmds.append(
            'mkdir -p "$WORKDIR/{parent}"\nrsync -a "$EXECROOT/{dir}/" "$WORKDIR/{dir}/"\n'.format(
                dir = d,
                parent = parent,
            ),
        )

    ctx.actions.run_shell(
        mnemonic = "MixRelease",
        inputs = inputs,
        outputs = [tar_out],
        progress_message = "mix release (web-ng)",
        command = """
set -euo pipefail

EXECROOT=$PWD

export HOME=$PWD/.mix_home
export MIX_HOME=$HOME/.mix
export HEX_HOME=$HOME/.hex
export REBAR_BASE_DIR=$HOME/.cache/rebar3
export MIX_ENV=prod
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export CARGO="$EXECROOT/{cargo_path}"
export RUSTC="$EXECROOT/{rustc_path}"
export PATH="$(dirname "$CARGO"):$(dirname "$RUSTC"):/opt/homebrew/bin:{elixir_home}/bin:{erlang_home}/bin:$PATH"

mkdir -p "$HOME"
WORKDIR=$(mktemp -d)
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
rsync -a "{src_dir}/" "$WORKDIR/"
{extra_copy}
cp "$EXECROOT/Cargo.toml" "$WORKDIR/Cargo.toml"
[ -f "$EXECROOT/Cargo.lock" ] && cp "$EXECROOT/Cargo.lock" "$WORKDIR/Cargo.lock"
mkdir -p "$WORKDIR/rust/srql" "$WORKDIR/rust/kvutil"
rsync -a "$EXECROOT/rust/srql/" "$WORKDIR/rust/srql/"
rsync -a "$EXECROOT/rust/kvutil/" "$WORKDIR/rust/kvutil/"
mkdir -p "$TMPROOT/rust/kvutil/proto"
rsync -a "$EXECROOT/proto/" "$TMPROOT/rust/kvutil/proto/"
mkdir -p "$SYS_TMP/rust/kvutil/proto"
rsync -a "$EXECROOT/proto/" "$SYS_TMP/rust/kvutil/proto/"

cd "$WORKDIR"
chmod -R u+w .
rm -rf priv/static
mkdir -p "$HOME/priv_static/assets/css"
ln -s "$HOME/priv_static" priv/static
: > priv/static/assets/css/app.css

# Fetch and compile deps, build assets, create release into Bazel output dir
mix local.hex --force
mix local.rebar --force
mix deps.get --only prod
mix deps.compile
TAILWIND_INPUT=assets/css/app.css \
TAILWIND_OUTPUT=priv/static/assets/css/app.css \
mix assets.deploy
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
            extra_copy = "".join(extra_copy_cmds),
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
        "extra_dirs": attr.string_list(doc = "Workspace-relative directories to copy into the build workspace"),
        "extra_dir_srcs": attr.label_list(allow_files = True, doc = "File inputs that back extra_dirs"),
    },
    toolchains = [
        "@rules_elixir//:toolchain_type",
        "@rules_rust//rust:toolchain",
    ],
)
