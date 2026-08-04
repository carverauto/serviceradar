load(
    "//tools:erlang_toolchain.bzl",
    "erlang_dirs",
    "maybe_install_erlang",
)

def _impl(ctx):
    outs = [
        ctx.actions.declare_file(f)
        for f in ctx.attr.outs
    ]

    (erlang_home, _, runfiles) = erlang_dirs(ctx)

    script = """set -euo pipefail

{maybe_install_erlang}

export SRCS="{srcs}"
export OUTS="{outs}"

"{erlang_home}"/bin/erl \\
    -noshell \\
    -eval "$1"
""".format(
        maybe_install_erlang = maybe_install_erlang(ctx),
        erlang_home = erlang_home,
        srcs = ctx.configuration.host_path_separator.join([src.path for src in ctx.files.srcs]),
        outs = ctx.configuration.host_path_separator.join([out.path for out in outs]),
    )

    inputs = depset(
        direct = ctx.files.srcs,
        transitive = [runfiles.files],
    )

    ctx.actions.run_shell(
        inputs = inputs,
        outputs = outs,
        command = script,
        arguments = [ctx.attr.expression],
    )

    return [
        DefaultInfo(files = depset(outs)),
    ]

erl_eval = rule(
    implementation = _impl,
    attrs = {
        "srcs": attr.label_list(allow_files = True),
        "outs": attr.string_list(),
        "expression": attr.string(
            mandatory = True,
        ),
    },
    toolchains = ["//tools:toolchain_type"],
)
