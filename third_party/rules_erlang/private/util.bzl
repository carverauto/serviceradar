load(
    "//:erlang_app_info.bzl",
    "ErlangAppInfo",
)
load(
    "//:util.bzl",
    "path_join",
)

_DEFAULT_ERL_LIBS_DIR = "deps"

def _app_name_from_ez(ez_file):
    base = ez_file.basename.removesuffix(".ez")
    (name, _, _version) = base.partition("-")
    return name

def additional_file_dest_relative_path(dep_label, f):
    if dep_label.workspace_root != "":
        workspace_root = dep_label.workspace_root.replace("external/", "../")
        rel_base = path_join(workspace_root, dep_label.package)
    else:
        rel_base = dep_label.package
    if rel_base != "":
        return f.short_path.replace(rel_base + "/", "")
    else:
        return f.short_path

def _link(ctx, source, dest):
    out = ctx.actions.declare_file(dest)
    ctx.actions.symlink(
        output = out,
        target_file = source,
    )
    return out

def erl_libs_contents(
        ctx,
        target_info = None,
        deps = [],
        ez_deps = [],
        headers = False,
        expand_ezs = False,
        dir = _DEFAULT_ERL_LIBS_DIR):
    erl_libs_files = []
    if headers and target_info != None:
        dep_path = path_join(dir, target_info.app_name)
        for hdr in target_info.include:
            rp = additional_file_dest_relative_path(ctx.label, hdr)
            dest = _link(ctx, hdr, path_join(dep_path, rp))
            erl_libs_files.append(dest)
    for dep in deps:
        lib_info = dep[ErlangAppInfo]
        dep_path = path_join(dir, lib_info.app_name)
        if headers:
            for hdr in lib_info.include:
                rp = additional_file_dest_relative_path(dep.label, hdr)
                dest = _link(ctx, hdr, path_join(dep_path, rp))
                erl_libs_files.append(dest)
        for src in lib_info.beam:
            if src.is_directory:
                if len(lib_info.beam) != 1:
                    fail("ErlangAppInfo.beam must be a collection of files, or a single ebin dir: {} {}".format(lib_info.app_name, lib_info.beam))
                dest = ctx.actions.declare_directory(path_join(dep_path, "ebin"))
                ctx.actions.run_shell(
                    inputs = [src],
                    outputs = [dest],
                    command = "cp -RL \"{}\"/* \"{}\"".format(src.path, dest.path),
                    mnemonic = "RulesErlangCopyErlLibsContentsSubdir",
                )
            else:
                dest = _link(ctx, src, path_join(dep_path, "ebin", src.basename))
            erl_libs_files.append(dest)
        for src in lib_info.priv:
            if src.is_directory:
                dest = ctx.actions.declare_directory(path_join(dep_path, "priv"))
                ctx.actions.run_shell(
                    inputs = [src],
                    outputs = [dest],
                    command = "cp -RL \"{}\"/. \"{}\"".format(src.path, dest.path),
                    mnemonic = "RulesErlangCopyErlLibsPrivDir",
                )
            else:
                rp = additional_file_dest_relative_path(dep.label, src)
                dest = _link(ctx, src, path_join(dep_path, rp))
            erl_libs_files.append(dest)
    for ez in ez_deps:
        if expand_ezs:
            app_name = _app_name_from_ez(ez)
            dest = ctx.actions.declare_directory(path_join(dir, app_name))
            ctx.actions.run_shell(
                inputs = [ez],
                outputs = [dest],
                command = "unzip -q {} -d {}".format(
                    ez.path,
                    dest.dirname,
                ),
                mnemonic = "RulesErlangCopyErlLibsExpandEz",
            )
        else:
            dest = ctx.actions.declare_file(path_join(dir, ez.basename))
            dest = _link(ctx, ez, path_join(dir, ez.basename))
        erl_libs_files.append(dest)
    return erl_libs_files

def to_erlang_string_list(strings):
    return "[" + ",".join(["\"{}\"".format(s) for s in strings]) + "]"

def to_erlang_atom_list(strings):
    return "[" + ",".join(strings) + "]"
