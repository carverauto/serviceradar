"""Generate the four topology schema snapshots with the pinned AshPostgres runtime."""

load("@bazel_skylib//lib:shell.bzl", "shell")
load("@rules_erlang//:erlang_app_info.bzl", "ErlangAppInfo", "flat_deps")
load("@rules_erlang//private:util.bzl", "erl_libs_contents")

def _impl(ctx):
    toolchain = ctx.toolchains[Label("@rules_elixir//:toolchain_type")]
    otp = toolchain.otpinfo
    elixir = toolchain.elixirinfo
    if otp.release_dir == None or elixir.release_dir == None:
        fail("World snapshots require the repository's hermetic OTP and Elixir toolchains")

    deps_dir = ctx.label.name + "_deps"
    libraries = erl_libs_contents(ctx, deps = flat_deps([ctx.attr.app]), dir = deps_dir)
    library_path = "/".join([ctx.bin_dir.path, ctx.label.package, deps_dir])
    elixir_home = elixir.elixir_home if elixir.elixir_home != None else elixir.release_dir.path

    ctx.actions.run_shell(
        inputs = libraries + [
            ctx.file.generator,
            otp.release_dir,
            otp.version_file,
            elixir.release_dir,
            elixir.version_file,
        ],
        outputs = ctx.outputs.outs,
        env = {"ERL_FLAGS": "+S 2:2 +A 2", "MIX_ENV": "test"},
        command = """set -euo pipefail
export PATH="$PWD/{otp}/bin:$PWD/{elixir}/bin:$PATH"
export ERL_LIBS="$PWD/{libraries}"
"$PWD/{elixir}/bin/elixir" {generator} {outputs}
""".format(
            otp = otp.erlang_home,
            elixir = elixir_home,
            libraries = library_path,
            generator = shell.quote(ctx.file.generator.path),
            outputs = " ".join([shell.quote(output.path) for output in ctx.outputs.outs]),
        ),
        mnemonic = "WorldSchemaSnapshots",
        progress_message = "Generating topology world schema snapshots with pinned AshPostgres",
    )

    return [DefaultInfo(files = depset(ctx.outputs.outs))]

world_snapshots = rule(
    implementation = _impl,
    attrs = {
        "app": attr.label(mandatory = True, providers = [ErlangAppInfo]),
        "generator": attr.label(mandatory = True, allow_single_file = [".exs"]),
        "outs": attr.output_list(mandatory = True),
    },
    toolchains = [Label("@rules_elixir//:toolchain_type")],
)
