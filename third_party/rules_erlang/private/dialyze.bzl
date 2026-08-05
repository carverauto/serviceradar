load(
    "//tools:erlang_toolchain.bzl",
    "erlang_dirs",
    "maybe_install_erlang",
)
load("//:erlang_app_info.bzl", "ErlangAppInfo")
load("//:util.bzl", "path_join", "windows_path")
load(":util.bzl", "erl_libs_contents")
load(":ct.bzl", "code_paths", "unique_short_dirnames")

def _impl(ctx):
    if ctx.attr.target == None and len(ctx.attr.beam) == 0:
        fail("Either 'target' or 'beam' must be set")

    apps_args = ""
    if len(ctx.attr.plt_apps) > 0:
        apps_args = "--apps " + " ".join(ctx.attr.plt_apps)

    if ctx.attr.plt == None:
        plt_args = "--build_plt"
    elif not ctx.attr.is_windows:
        plt_args = "--plt " + ctx.file.plt.short_path + " --no_check_plt"
    else:
        plt_args = "--plt " + windows_path(ctx.file.plt.short_path) + " --no_check_plt"

    erl_libs_dir = ctx.label.name + "_deps"

    erl_libs_files = erl_libs_contents(
        ctx,
        deps = ctx.attr.libs,
        dir = erl_libs_dir,
    )

    erl_libs_path = ""
    if len(erl_libs_files) > 0:
        erl_libs_path = path_join(ctx.label.package, erl_libs_dir)

    dirs = code_paths(ctx.attr.target)
    dirs.extend(unique_short_dirnames(ctx.files.beam))

    (erlang_home, _, runfiles) = erlang_dirs(ctx)

    if not ctx.attr.is_windows:
        output = ctx.actions.declare_file(ctx.label.name)
        script = """\
#!/usr/bin/env bash
set -euo pipefail

{maybe_install_erlang}

export HOME=${{TEST_TMPDIR}}

if [ -n "{erl_libs_path}" ]; then
    export ERL_LIBS={erl_libs_path}
fi

set -x
"{erlang_home}"/bin/dialyzer {apps_args} \\
    {plt_args} \\
    -r {dirs} {opts}{check_warnings}
""".format(
            maybe_install_erlang = maybe_install_erlang(ctx, short_path = True),
            erlang_home = erlang_home,
            erl_libs_path = erl_libs_path,
            apps_args = apps_args,
            plt_args = plt_args,
            dirs = " ".join(dirs),
            opts = " ".join(ctx.attr.dialyzer_opts),
            check_warnings = " || test $? -eq 2" if not ctx.attr.warnings_as_errors else "",
        )
    else:
        output = ctx.actions.declare_file(ctx.label.name + ".bat")
        script = """
if [{erl_libs_path}] == [] goto :dialyze
REM TEST_SRCDIR is provided by bazel but with unix directory separators
set ERL_LIBS=%TEST_SRCDIR%/%TEST_WORKSPACE%/{erl_libs_path}
set ERL_LIBS=%ERL_LIBS:/=\\%
:dialyze

"{erlang_home}\\bin\\dialyzer" {apps_args} ^
    {plt_args} ^
    -r {dirs} {opts}
if %ERRORLEVEL% EQU 0 EXIT /B 0
{check_warnings}
EXIT /B 1
""".format(
            erlang_home = windows_path(erlang_home),
            erl_libs_path = erl_libs_path,
            apps_args = apps_args,
            plt_args = plt_args,
            dirs = " ".join(dirs),
            opts = " ".join(ctx.attr.dialyzer_opts),
            check_warnings = "if %ERRORLEVEL% EQU 2 EXIT /B 0" if not ctx.attr.warnings_as_errors else "",
        ).replace("\n", "\r\n")

    ctx.actions.write(
        output = output,
        content = script,
    )

    runfiles = runfiles.merge_all([
        ctx.runfiles(ctx.files.plt + erl_libs_files + ctx.files.beam),
        ctx.attr.target[DefaultInfo].default_runfiles,
    ])
    return [DefaultInfo(
        runfiles = runfiles,
        executable = output,
    )]

dialyze_test = rule(
    implementation = _impl,
    attrs = {
        "is_windows": attr.bool(mandatory = True),
        "plt": attr.label(
            allow_single_file = [".plt"],
        ),
        "beam": attr.label_list(
            allow_files = [".beam"],
        ),
        "target": attr.label(
            providers = [ErlangAppInfo],
        ),
        "plt_apps": attr.string_list(),
        "libs": attr.label_list(
            providers = [ErlangAppInfo],
        ),
        "dialyzer_opts": attr.string_list(
            default = [
                "-Werror_handling",
                "-Wunmatched_returns",
            ],
        ),
        "warnings_as_errors": attr.bool(default = True),
    },
    toolchains = ["//tools:toolchain_type"],
    test = True,
)
