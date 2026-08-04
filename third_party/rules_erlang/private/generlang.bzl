load(
    "//tools:erlang_toolchain.bzl",
    "erlang_dirs",
    "maybe_install_erlang",
)
load(
    "//:util.bzl",
    "path_join",
)

def _with_subs(s, substitutions):
    r = s
    for (k, v) in substitutions.items():
        r = r.replace(k, v)
    return r

def _impl(ctx):
    (erlang_home, _, runfiles) = erlang_dirs(ctx)

    outs = [
        ctx.actions.declare_file(out)
        for out in ctx.attr.outs
    ]

    inputs = depset(
        direct = ctx.files.srcs,
        transitive = [runfiles.files],
    )

    substitutions = {
        "$(SRCS)": " ".join([src.path for src in ctx.files.srcs]),
        "$(OUTS)": " ".join([out.path for out in outs]),
        "$(RULEDIR)": path_join(ctx.bin_dir.path, ctx.label.workspace_root, ctx.label.package),
    }
    for src in ctx.attr.srcs:
        files = src[DefaultInfo].files.to_list()
        if len(files) == 1:
            substitutions["$(location {})".format(src.label.name)] = files[0].path
    if len(ctx.files.srcs) == 1:
        substitutions["$<"] = ctx.files.srcs[0].path
    if len(outs) == 1:
        substitutions["$@"] = outs[0].path

    cmd = _with_subs(ctx.attr.cmd, substitutions)

    script = """set -euo pipefail

{maybe_install_erlang}

export PATH="{erlang_home}"/bin:${{PATH}}

{cmd}
""".format(
        maybe_install_erlang = maybe_install_erlang(ctx),
        erlang_home = erlang_home,
        cmd = cmd,
    )

    ctx.actions.run_shell(
        inputs = inputs,
        outputs = outs,
        command = script,
    )

    return [
        DefaultInfo(files = depset(outs)),
    ]

generlang = rule(
    implementation = _impl,
    attrs = {
        "srcs": attr.label_list(
            allow_files = True,
        ),
        "outs": attr.string_list(),
        "cmd": attr.string(
            mandatory = True,
        ),
    },
    toolchains = ["//tools:toolchain_type"],
)
