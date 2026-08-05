load("//:erlang_app_info.bzl", "ErlangAppInfo")
load("//:util.bzl", "path_join")
load(":util.bzl", "erl_libs_contents")
load(
    "//tools:erlang_toolchain.bzl",
    "erlang_dirs",
    "maybe_install_erlang",
)

def unique_dirnames(files):
    dirs = []
    for f in files:
        dirname = f.path if f.is_directory else f.dirname
        if dirname not in dirs:
            dirs.append(dirname)
    return dirs

def _dirname(path):
    return path.rpartition("/")[0]

def _impl(ctx):
    package_dir = path_join(
        ctx.label.workspace_root,
        ctx.label.package,
    )

    (erlang_home, _, runfiles) = erlang_dirs(ctx)

    outputs = ctx.outputs.outs

    out_dirs = unique_dirnames(outputs)
    if len(out_dirs) > 1:
        fail(ctx.attr.outs, "do not share a common parent directory")
    out_dir = out_dirs[0]

    script = """set -euo pipefail


mkdir -p {out_dir}

"{erlang_home}"/bin/erlc \\
    -o "{out_dir}" \\
    "$@"
    """.format(
        maybe_install_erlang = maybe_install_erlang(ctx),
        erlang_home = erlang_home,
        out_dir = out_dir,
    )

    inputs = depset(
        direct = ctx.files.srcs,
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

erlang_xrl_yrl = rule(
    implementation = _impl,
    attrs = {
        "app_name": attr.string(),
        "srcs": attr.label_list(
            mandatory = True,
            doc = "The xrl or yrl files to compile",
            allow_files = [".xrl", ".yrl"],
        ),
        "deps": attr.label_list(
            providers = [ErlangAppInfo],
        ),
        "outs": attr.output_list(
            doc = "The erl file to be created (same basename like the src)",
            mandatory = True,
        ),
    },
    toolchains = ["//tools:toolchain_type"],
)
