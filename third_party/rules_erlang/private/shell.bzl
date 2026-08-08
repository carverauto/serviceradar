load("//:erlang_app_info.bzl", "ErlangAppInfo", "flat_deps")
load(
    "//:util.bzl",
    "path_join",
    "windows_path",
)
load(":util.bzl", "erl_libs_contents")
load(
    "//tools:erlang_toolchain.bzl",
    "erlang_dirs",
    "maybe_install_erlang",
)

def _impl(ctx):
    erl_libs_dir = ctx.attr.name + "_deps"

    erl_libs_files = erl_libs_contents(
        ctx,
        deps = flat_deps(ctx.attr.deps),
        ez_deps = ctx.files.ez_deps,
        dir = erl_libs_dir,
    )

    package = ctx.label.package

    erl_libs_path = path_join(package, erl_libs_dir)

    (erlang_home, _, runfiles) = erlang_dirs(ctx)

    if not ctx.attr.is_windows:
        output = ctx.actions.declare_file(ctx.label.name)
        script = """\
#!/usr/bin/env bash
set -euo pipefail

{maybe_install_erlang}

export ERL_LIBS=$PWD/{erl_libs_path}

set -x
"{erlang_home}"/bin/erl {extra_erl_args} $@
""".format(
            maybe_install_erlang = maybe_install_erlang(ctx, short_path = True),
            erlang_home = erlang_home,
            erl_libs_path = erl_libs_path,
            extra_erl_args = " ".join(ctx.attr.extra_erl_args),
        )
    else:
        output = ctx.actions.declare_file(ctx.label.name + ".bat")
        script = """@echo off

set ERL_LIBS=%cd%\\{erl_libs_path}

echo on
"{erlang_home}\\bin\\erl" {extra_erl_args} %* || exit /b 1
""".format(
            erlang_home = windows_path(erlang_home),
            erl_libs_path = windows_path(erl_libs_path),
            extra_erl_args = " ".join(ctx.attr.extra_erl_args),
        ).replace("\n", "\r\n")

    ctx.actions.write(
        output = output,
        content = script,
    )

    runfiles = ctx.runfiles(
        files = ctx.files.data,
        transitive_files = depset(erl_libs_files),
    )

    return [DefaultInfo(
        runfiles = runfiles,
        executable = output,
    )]

shell = rule(
    implementation = _impl,
    attrs = {
        "is_windows": attr.bool(mandatory = True),
        "deps": attr.label_list(providers = [ErlangAppInfo]),
        "ez_deps": attr.label_list(
            allow_files = [".ez"],
        ),
        "extra_erl_args": attr.string_list(),
        "data": attr.label_list(allow_files = True),
    },
    toolchains = ["//tools:toolchain_type"],
    executable = True,
)
