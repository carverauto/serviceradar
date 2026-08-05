load(
    "//:erlang_app_info.bzl",
    "ErlangAppInfo",
    "flat_deps",
)
load(
    "//:util.bzl",
    "path_join",
)
load(
    ":util.bzl",
    "additional_file_dest_relative_path",
)

def _impl(ctx):
    deps = flat_deps(ctx.attr.deps)

    files = []
    for dep in deps:
        lib_info = dep[ErlangAppInfo]
        dep_path = path_join(ctx.label.name, lib_info.app_name)
        for src in lib_info.srcs + lib_info.priv + lib_info.license_files:
            rp = additional_file_dest_relative_path(dep.label, src)
            dest = ctx.actions.declare_file(path_join(dep_path, rp))
            ctx.actions.symlink(output = dest, target_file = src)
            files.append(dest)
    for ez in ctx.files.ez_deps:
        dest = ctx.actions.declare_file(path_join(ctx.label.name, ez.basename))
        ctx.actions.symlink(output = dest, target_file = ez)
        files.append(dest)

    return [DefaultInfo(
        files = depset(files),
    )]

source_tree = rule(
    implementation = _impl,
    attrs = {
        "deps": attr.label_list(
            providers = [ErlangAppInfo],
            mandatory = True,
        ),
        "ez_deps": attr.label_list(
            allow_files = [".ez"],
        ),
    },
)
