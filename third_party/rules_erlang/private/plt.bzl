load("//:erlang_app_info.bzl", "ErlangAppInfo", "flat_deps")
load("//:util.bzl", "path_join")
load(":util.bzl", "erl_libs_contents")
load(
    "//tools:erlang_toolchain.bzl",
    "erlang_dirs",
    "maybe_install_erlang",
)

_IGNORE_WARNINGS = """if [ $R -eq 2 ]; then
    exit 0
fi
"""

def _impl(ctx):
    logfile = ctx.actions.declare_file(ctx.outputs.plt.basename + ".log")
    home_dir = ctx.actions.declare_directory(ctx.label.name + "_home")

    erl_libs_dir = ctx.label.name + "_deps"

    erl_libs_files = erl_libs_contents(
        ctx,
        deps = ctx.attr.libs,
        dir = erl_libs_dir,
    )

    erl_libs_path = ""
    if len(erl_libs_files) > 0:
        erl_libs_path = path_join(
            ctx.bin_dir.path,
            ctx.label.workspace_root,
            ctx.label.package,
            erl_libs_dir,
        )

    target_files_dir = ctx.label.name + "_files"

    deps = []
    if ctx.attr.for_target != None:
        deps.extend(flat_deps(ctx.attr.for_target[ErlangAppInfo].deps + ctx.attr.deps))
    else:
        deps.extend(flat_deps(ctx.attr.deps))

    target_files = erl_libs_contents(
        ctx,
        deps = deps,
        dir = target_files_dir,
        expand_ezs = True,
        ez_deps = ctx.files.ez_deps,
    )

    target_files_path = ""
    if len(target_files) > 0:
        target_files_path = path_join(
            ctx.bin_dir.path,
            ctx.label.workspace_root,
            ctx.label.package,
            target_files_dir,
        )

    args = ctx.actions.args()

    if ctx.file.plt == None:
        args.add("--build_plt")
    else:
        args.add("--plt")
        args.add(ctx.file.plt)
        args.add("--no_check_plt")
        args.add("--add_to_plt")

    apps = []
    apps.extend(ctx.attr.apps)
    if ctx.attr.for_target != None:
        apps.extend(ctx.attr.for_target[ErlangAppInfo].extra_apps)
    if len(apps) > 0:
        args.add("--apps")
        args.add_all(apps)

    if target_files_path != "":
        args.add("-r")
        args.add(target_files_path)

    args.add_all(ctx.attr.extra_args)

    args.add("--output_plt")
    args.add(ctx.outputs.plt)

    args.add_all(ctx.attr.dialyzer_opts)

    (erlang_home, _, runfiles) = erlang_dirs(ctx)

    script = """\
#!/usr/bin/env bash
set -euo pipefail

{maybe_install_erlang}

# without HOME being set, dialyzer will error regarding a default plt
export HOME={home}

if [ -n "{erl_libs_path}" ]; then
    export ERL_LIBS={erl_libs_path}
fi

set +e
set -x
"{erlang_home}"/bin/dialyzer $@ > {logfile}
R=$?
set +x
set -e
if [ ! $R -eq 0 ]; then
    echo "DIALYZER: There were warnings and/or errors"
fi
echo "DIALYZER: Output written to {logfile}"
{ignore_warnings_clause}
exit $R
""".format(
        maybe_install_erlang = maybe_install_erlang(ctx),
        erlang_home = erlang_home,
        home = home_dir.path,
        erl_libs_path = erl_libs_path,
        logfile = logfile.path,
        ignore_warnings_clause = _IGNORE_WARNINGS if ctx.attr.ignore_warnings else "",
    )

    inputs = depset(
        direct = ctx.files.plt + erl_libs_files + target_files,
        transitive = [runfiles.files],
    )

    ctx.actions.run_shell(
        inputs = inputs,
        outputs = [ctx.outputs.plt, logfile, home_dir],
        command = script,
        arguments = [args],
        mnemonic = "DIALYZER",
    )

plt = rule(
    implementation = _impl,
    attrs = {
        "plt": attr.label(
            allow_single_file = [".plt"],
        ),
        "apps": attr.string_list(),
        "extra_args": attr.string_list(),
        "libs": attr.label_list(
            providers = [ErlangAppInfo],
        ),
        "deps": attr.label_list(
            providers = [ErlangAppInfo],
        ),
        "ez_deps": attr.label_list(
            allow_files = [".ez"],
        ),
        "for_target": attr.label(
            providers = [ErlangAppInfo],
        ),
        "dialyzer_opts": attr.string_list(),
        "ignore_warnings": attr.bool(
            default = True,
        ),
    },
    outputs = {
        "plt": ".%{name}.plt",
    },
    toolchains = ["//tools:toolchain_type"],
)
