load(
    "//tools:erlang_toolchain.bzl",
    "erlang_dirs",
    "maybe_install_erlang",
)

def _impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.out if ctx.attr.out != "" else ctx.label.name)

    if ctx.attr.src != None and ctx.attr.beam != None:
        fail("both src and beam attributes cannot be specified simultaneously")
    elif ctx.attr.src != None:
        body = "{{source,\"{}\"}}".format(ctx.file.src.path)
    else:
        body = "{{beam,\"{}\"}}".format(ctx.file.beam.path)

    args = ctx.actions.args()
    args.add("""EscriptPath = "{out}",
io:format("Assembiling ~s escript...~n", [EscriptPath]),
ok = escript:create(EscriptPath,
                    [shebang, comment,
                    {body}]),
io:format("done.~n", []),
halt().
""".format(
        out = out.path,
        body = body,
    ))

    (erlang_home, erlang_release_dir, runfiles) = erlang_dirs(ctx)

    inputs = depset(
        direct = ctx.files.src + ctx.files.beam,
        transitive = [runfiles.files],
    )

    ctx.actions.run_shell(
        inputs = inputs,
        outputs = [out],
        command = """set -euo pipefail

{maybe_install_erlang}

"{erlang_home}"/bin/erl -noshell -eval "$@"
""".format(
            maybe_install_erlang = maybe_install_erlang(ctx),
            erlang_home = erlang_home,
        ),
        arguments = [args],
    )

    return [
        DefaultInfo(
            executable = out,
        ),
    ]

escript_flat = rule(
    implementation = _impl,
    attrs = {
        "src": attr.label(
            allow_single_file = [".erl"],
        ),
        "beam": attr.label(
            allow_single_file = [".beam"],
        ),
        "out": attr.string(),
    },
    toolchains = ["//tools:toolchain_type"],
)
