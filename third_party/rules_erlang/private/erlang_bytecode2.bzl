load("//:erlang_app_info.bzl", "ErlangAppInfo", "flat_deps")
load("//:util.bzl", "path_join")
load(":erlang_bytecode.bzl", "unique_dirnames")
load(":util.bzl", "erl_libs_contents")
load(
    "//tools:erlang_toolchain.bzl",
    "erlang_dirs",
    "maybe_install_erlang",
)

ErlcOptsInfo = provider(
    doc = "Reusable set of erlc options",
    fields = {
        "values": "Strings to be passed as additional options to erlc",
    },
)

def _impl(ctx):
    if len(ctx.attr.outs) == 0:
        fail("attr outs must not be empty")

    outputs = [
        ctx.actions.declare_file(f.name)
        for f in ctx.attr.outs
    ]

    erl_libs_dir = ctx.label.name + "_deps"

    target = None
    if ctx.attr.app_name != "":
        target = ErlangAppInfo(
            app_name = ctx.attr.app_name,
            include = ctx.files.hdrs,
        )

    package_dir = path_join(
        ctx.label.workspace_root,
        ctx.label.package,
    )

    # this actually just needs to be headers and behaviours, in the context of compiling,
    # though it must include the transitive headers and behaviors. Therefore this file
    # could have it's own optimized version of `erl_libs_contents`
    erl_libs_files = erl_libs_contents(
        ctx,
        target_info = target,
        headers = True,
        dir = erl_libs_dir,
        deps = flat_deps(ctx.attr.deps),
        ez_deps = ctx.files.ez_deps,
    )

    erl_libs_path = ""
    if len(erl_libs_files) > 0:
        erl_libs_path = path_join(
            ctx.bin_dir.path,
            ctx.label.workspace_root,
            ctx.label.package,
            erl_libs_dir,
        )

    out_dirs = unique_dirnames(outputs)
    if len(out_dirs) > 1:
        fail(ctx.attr.outs, "do not share a common parent directory")
    out_dir = out_dirs[0]

    include_args = []
    if package_dir != "":
        include_args.extend(["-I", package_dir])
    for dir in unique_dirnames(ctx.files.hdrs):
        include_args.extend(["-I", dir])
    if erl_libs_path != "":
        include_args.extend(["-I", "${ERL_LIBS}"])

    pa_args = []
    for dir in unique_dirnames(ctx.files.beam):
        pa_args.extend(["-pa", dir])

    (erlang_home, _, runfiles) = erlang_dirs(ctx)

    script = """set -euo pipefail

{maybe_install_erlang}

if [ -n "{erl_libs_path}" ]; then
    export ERL_LIBS={erl_libs_path}
fi

"{erlang_home}"/bin/erlc \\
    -v {include_args} {pa_args} \\
    -o {out_dir} {erlc_opts} \\
    $@
    """.format(
        maybe_install_erlang = maybe_install_erlang(ctx),
        erlang_home = erlang_home,
        erl_libs_path = erl_libs_path,
        include_args = " ".join(include_args),
        pa_args = " ".join(pa_args),
        out_dir = out_dir,
        erlc_opts = " ".join(ctx.attr.erlc_opts[ErlcOptsInfo].values),
    )

    inputs = depset(
        direct = ctx.files.hdrs + ctx.files.srcs + ctx.files.beam + erl_libs_files,
        transitive = [runfiles.files],
    )

    srcs = ctx.actions.args()
    srcs.add_all(ctx.files.srcs)

    ctx.actions.run_shell(
        inputs = inputs,
        outputs = outputs,
        command = script,
        arguments = [srcs],
        mnemonic = "ERLC",
    )

    return [
        DefaultInfo(files = depset(outputs)),
    ]

erlang_bytecode = rule(
    implementation = _impl,
    attrs = {
        "app_name": attr.string(),
        "hdrs": attr.label_list(
            allow_files = True,
        ),
        "srcs": attr.label_list(
            mandatory = True,
            allow_files = [".erl"],
        ),
        "beam": attr.label_list(
            allow_files = [".beam"],
        ),
        "deps": attr.label_list(
            providers = [ErlangAppInfo],
        ),
        "ez_deps": attr.label_list(
            allow_files = [".ez"],
        ),
        "erlc_opts": attr.label(
            providers = [ErlcOptsInfo],
        ),
        "outs": attr.output_list(
            mandatory = True,
        ),
    },
    toolchains = ["//tools:toolchain_type"],
)

def _erlc_opts_impl(ctx):
    return [ErlcOptsInfo(values = ctx.attr.values)]

erlc_opts = rule(
    implementation = _erlc_opts_impl,
    attrs = {
        "values": attr.string_list(),
    },
    provides = [ErlcOptsInfo],
)
