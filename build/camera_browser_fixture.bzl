"""Generate browser media from the production packager and recovered spool."""

load("@bazel_skylib//lib:shell.bzl", "shell")
load("@rules_erlang//:erlang_app_info.bzl", "ErlangAppInfo", "flat_deps")
load("@rules_erlang//private:util.bzl", "erl_libs_contents")

def _impl(ctx):
    toolchain = ctx.toolchains[Label("@rules_elixir//:toolchain_type")]
    otp = toolchain.otpinfo
    elixir = toolchain.elixirinfo
    if otp.release_dir == None or elixir.release_dir == None:
        fail("Camera browser fixtures require the hermetic OTP and Elixir toolchains")

    deps_dir = ctx.label.name + "_deps"
    libraries = erl_libs_contents(ctx, deps = flat_deps([ctx.attr.app]), dir = deps_dir)
    library_path = "/".join([ctx.bin_dir.path, ctx.label.package, deps_dir])
    elixir_home = elixir.elixir_home if elixir.elixir_home != None else elixir.release_dir.path
    ffmpeg = [f for f in ctx.files.media_tools if f.basename == "ffmpeg"]
    if len(ffmpeg) != 1:
        fail("Expected one pinned FFmpeg executable")

    ctx.actions.run_shell(
        inputs = libraries + ctx.files.media_tools + [
            ctx.file.generator,
            otp.release_dir,
            otp.version_file,
            elixir.release_dir,
            elixir.version_file,
        ],
        outputs = [ctx.outputs.out],
        env = {"ERL_FLAGS": "+S 2:2 +A 2 +fnu", "MIX_ENV": "test"},
        command = """set -euo pipefail
export PATH="$PWD/{otp}/bin:$PWD/{elixir}/bin:$PATH"
export ERL_LIBS="$PWD/{libraries}"
"$PWD/{elixir}/bin/elixir" {generator} {ffmpeg} {output}
""".format(
            otp = otp.erlang_home,
            elixir = elixir_home,
            libraries = library_path,
            generator = shell.quote(ctx.file.generator.path),
            ffmpeg = shell.quote(ffmpeg[0].path),
            output = shell.quote(ctx.outputs.out.path),
        ),
        mnemonic = "CameraBrowserFixture",
        progress_message = "Packaging and recovering synthetic camera media for Chromium",
        execution_requirements = {"timeout": "120"},
    )

    return [DefaultInfo(files = depset([ctx.outputs.out]))]

camera_browser_fixture = rule(
    implementation = _impl,
    attrs = {
        "app": attr.label(mandatory = True, providers = [ErlangAppInfo]),
        "generator": attr.label(mandatory = True, allow_single_file = [".exs"]),
        "media_tools": attr.label(mandatory = True, allow_files = True),
        "out": attr.output(mandatory = True),
    },
    toolchains = [Label("@rules_elixir//:toolchain_type")],
)
