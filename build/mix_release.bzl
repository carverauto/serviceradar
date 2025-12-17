"""Lightweight rule to run `mix release` hermetically using rules_elixir toolchains."""

def _mix_release_impl(ctx):
    toolchain = ctx.toolchains["@rules_elixir//:toolchain_type"]
    otp = toolchain.otpinfo
    elixir = toolchain.elixirinfo

    erlang_home = otp.erlang_home
    elixir_home = elixir.elixir_home or elixir.release_dir.path

    release_dir = ctx.actions.declare_directory(ctx.label.name + "_release")
    tar_out = ctx.outputs.out

    toolchain_inputs = [
        otp.version_file,
        elixir.version_file,
    ]
    if getattr(otp, "release_dir_tar", None):
        toolchain_inputs.append(otp.release_dir_tar)
    if getattr(elixir, "release_dir", None):
        toolchain_inputs.append(elixir.release_dir)

    inputs = depset(toolchain_inputs + ctx.files.srcs + ctx.files.data)

    ctx.actions.run_shell(
        mnemonic = "MixRelease",
        inputs = inputs,
        outputs = [release_dir, tar_out],
        progress_message = "mix release (web-ng)",
        command = """
set -euo pipefail

export HOME=$PWD/.mix_home
export MIX_HOME=$HOME/.mix
export HEX_HOME=$HOME/.hex
export REBAR_BASE_DIR=$HOME/.cache/rebar3
export MIX_ENV=prod
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export PATH="{elixir_home}/bin:{erlang_home}/bin:$PATH"

mkdir -p "$HOME"
cd "{src_dir}"

# Fetch and compile deps, build assets, create release into Bazel output dir
mix local.hex --force
mix local.rebar --force
mix deps.get --only prod
mix deps.compile
mix assets.deploy
mix release --path "{release_dir}"

# Package release to tar output
tar -czf "{tar_out}" -C "{release_dir}" .
""".format(
            elixir_home = elixir_home,
            erlang_home = erlang_home,
            src_dir = ctx.attr.src_dir,
            release_dir = release_dir.path,
            tar_out = tar_out.path,
        ),
        use_default_shell_env = False,
    )

    return [
        DefaultInfo(
            files = depset([tar_out, release_dir]),
        ),
    ]

mix_release = rule(
    implementation = _mix_release_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = True, doc = "Web-NG sources"),
        "data": attr.label_list(allow_files = True, doc = "Additional data files (e.g., priv/static)"),
        "src_dir": attr.string(default = "web-ng", doc = "Path to the web-ng project root relative to workspace"),
        "out": attr.output(mandatory = True),
    },
    toolchains = ["@rules_elixir//:toolchain_type"],
)
