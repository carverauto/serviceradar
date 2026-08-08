load("//:erlang_app_info.bzl", "ErlangAppInfo")
load(
    "//tools:erlang_toolchain.bzl",
    "erlang_dirs",
    "maybe_install_erlang",
)
load(":util.bzl", "additional_file_dest_relative_path")

def _extract_version(p):
    return "erl -eval '{ok, [{application, _, AppInfo}]} = file:consult(\"" + p + "\"), Version = proplists:get_value(vsn, AppInfo), io:fwrite(Version), halt().' -noshell"

def _app_file(lib_info):
    for f in lib_info.beam:
        if f.basename.endswith(".app"):
            return f
    fail(".app file not found in {}".format(lib_info))

def _impl(ctx):
    lib_info = ctx.attr.app[ErlangAppInfo]

    (erlang_home, _, runfiles) = erlang_dirs(ctx)

    inputs = runfiles.files.to_list()
    inputs.extend(lib_info.include)
    inputs.extend(lib_info.beam)
    inputs.extend(lib_info.priv)

    workspace = ctx.actions.declare_directory(ctx.label.name)
    archive = ctx.actions.declare_file("%s.ez" % lib_info.app_name)

    stamp = ctx.attr.stamp == 1 or (ctx.attr.stamp == -1 and
                                    ctx.attr.private_stamp_detect)
    epoch = "1980-01-01T00:00:00"

    build_directory_commands = [
        'mkdir "{workspace}/{app_name}-$VERSION"'.format(
            workspace = workspace.path,
            app_name = lib_info.app_name,
        ),
    ]
    for f in lib_info.include + lib_info.beam + lib_info.priv:
        rp = additional_file_dest_relative_path(
            ctx.attr.app.label,
            f,
        )
        dest = "{workspace}/{app_name}-$VERSION/{rp}".format(
            workspace = workspace.path,
            app_name = lib_info.app_name,
            rp = rp,
        )
        build_directory_commands.extend([
            'mkdir -p $(dirname "{dest}")'.format(dest = dest),
            'cp -p "{f}" "{dest}"'.format(f = f.path, dest = dest),
        ])
        if not stamp:
            build_directory_commands.extend([
                'touch -a -m -d {} "{}"'.format(epoch, dest),
                'touch -a -m -d {} "$(dirname "{}")"'.format(epoch, dest),
            ])
    if not stamp:
        build_directory_commands.append(
            'touch -a -m -d {epoch} "{workspace}/{app_name}-$VERSION"'.format(
                epoch = epoch,
                workspace = workspace.path,
                app_name = lib_info.app_name,
            ),
        )

    ctx.actions.run_shell(
        inputs = inputs,
        outputs = [archive, workspace],
        command = """set -euo pipefail

{maybe_install_erlang}

VERSION=$({erlang_home}/bin/{extract_version})

{build_directory_commands}

"{erlang_home}"/bin/erl \\
    -noshell \\
    -eval "zip:create(\\"{workspace}/{app_name}-$VERSION.ez\\",
            [\\"{app_name}-$VERSION\\"],
            [{{cwd, \\"{workspace}\\"}},
             {{compress, all}},
             {{uncompress, [\\".beam\\",\\".app\\"]}}]),
           halt()."

cp "{workspace}/{app_name}-$VERSION.ez" "{archive}"
""".format(
            maybe_install_erlang = maybe_install_erlang(ctx),
            erlang_home = erlang_home,
            extract_version = _extract_version(_app_file(lib_info).path),
            build_directory_commands = "\n".join(build_directory_commands),
            workspace = workspace.path,
            archive = archive.path,
            app_name = lib_info.app_name,
        ),
        mnemonic = "EZ",
    )

    return [DefaultInfo(files = depset([archive]))]

ez = rule(
    implementation = _impl,
    attrs = {
        "app": attr.label(
            providers = [ErlangAppInfo],
            mandatory = True,
        ),
        "stamp": attr.int(default = -1),
        # Is --stamp set on the command line?
        # TODO(https://github.com/bazelbuild/rules_pkg/issues/340): Remove this.
        "private_stamp_detect": attr.bool(default = False),
    },
    toolchains = ["//tools:toolchain_type"],
)
