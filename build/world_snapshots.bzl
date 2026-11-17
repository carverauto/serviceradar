"""Generate AshPostgres schema snapshots and migrations with the pinned AshPostgres runtime.

Generated Elixir outputs (`.ex`, `.exs`) are formatted as `mix format` formats them in the app's
Mix project: the app's own `.formatter.exs`, the `.formatter.exs` of every dependency it imports,
and its formatter plugins, applied by `Mix.Tasks.Format` itself until the text stops changing. A
committed copy kept current by a `write_source_files` diff test is therefore a fixed point of the
pre-commit `mix format` hook, so the hook has nothing to change.
"""

load("@bazel_skylib//lib:shell.bzl", "shell")
load("@rules_erlang//:erlang_app_info.bzl", "ErlangAppInfo", "flat_deps")
load("@rules_erlang//private:util.bzl", "additional_file_dest_relative_path", "erl_libs_contents")

def _root_formatter(target):
    for f in target[ErlangAppInfo].srcs:
        if additional_file_dest_relative_path(target.label, f) == ".formatter.exs":
            return f
    return None

def _format_command(ctx, elixir_home, deps):
    elixir_outputs = [out for out in ctx.outputs.outs if out.extension in ("ex", "exs")]
    if not elixir_outputs:
        return [], ""

    dot_formatter = _root_formatter(ctx.attr.app)
    if dot_formatter == None:
        fail("{} generates Elixir, but {} has no .formatter.exs in its srcs to format it with".format(
            ctx.label,
            ctx.attr.app.label,
        ))

    # Mix reads only the dependencies named by `import_deps`; staging every dependency's
    # formatter keeps that list in the project's .formatter.exs rather than here.
    inputs = [ctx.file._formatter, dot_formatter]
    dep_args = []
    for dep in deps:
        dep_formatter = _root_formatter(dep)
        if dep_formatter != None and dep.label != ctx.attr.app.label:
            inputs.append(dep_formatter)
            dep_args.append(shell.quote("{}={}".format(dep[ErlangAppInfo].app_name, dep_formatter.dirname)))

    command = """"$PWD/{elixir}/bin/elixir" {script} {dot_formatter} {deps} -- {outputs}
""".format(
        elixir = elixir_home,
        script = shell.quote(ctx.file._formatter.path),
        dot_formatter = shell.quote(dot_formatter.path),
        deps = " ".join(dep_args),
        outputs = " ".join([shell.quote(out.path) for out in elixir_outputs]),
    )
    return inputs, command

def _impl(ctx):
    toolchain = ctx.toolchains[Label("@rules_elixir//:toolchain_type")]
    otp = toolchain.otpinfo
    elixir = toolchain.elixirinfo
    if otp.release_dir == None or elixir.release_dir == None:
        fail("World snapshots require the repository's hermetic OTP and Elixir toolchains")

    deps_dir = ctx.label.name + "_deps"
    deps = flat_deps([ctx.attr.app])
    libraries = erl_libs_contents(ctx, deps = deps, dir = deps_dir)
    library_path = "/".join([ctx.bin_dir.path, ctx.label.package, deps_dir])
    elixir_home = elixir.elixir_home if elixir.elixir_home != None else elixir.release_dir.path
    format_inputs, format_command = _format_command(ctx, elixir_home, deps)

    ctx.actions.run_shell(
        inputs = libraries + ctx.files.srcs + format_inputs + [
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
"$PWD/{elixir}/bin/elixir" {generator} {outputs} {sources}
{format_command}""".format(
            otp = otp.erlang_home,
            elixir = elixir_home,
            libraries = library_path,
            generator = shell.quote(ctx.file.generator.path),
            sources = " ".join([shell.quote(source.path) for source in ctx.files.srcs]),
            outputs = " ".join([shell.quote(output.path) for output in ctx.outputs.outs]),
            format_command = format_command,
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
        "srcs": attr.label_list(allow_files = True),
        "_formatter": attr.label(
            default = Label("//build:format_generated_elixir.exs"),
            allow_single_file = [".exs"],
        ),
    },
    toolchains = [Label("@rules_elixir//:toolchain_type")],
)
