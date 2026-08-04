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
    "//tools:erlang_toolchain.bzl",
    "erlang_dirs",
    "maybe_install_erlang",
)
load(
    ":util.bzl",
    "additional_file_dest_relative_path",
)

DEFAULT_HEADERS = [
    "shebang",
    "comment",
]

def _impl(ctx):
    name = ctx.attr.out if ctx.attr.out != "" else ctx.label.name

    output = ctx.actions.declare_file(name)

    contents_dir = ctx.actions.declare_directory("%s_contents" % name)

    entries = {}
    for f in ctx.files.srcs + ctx.files.hdrs + ctx.files.beam:
        if f.basename in entries:
            fail("Duplicate entry for %s: '%s'" % (f, f.basename))
        entries[f.basename] = f
    for dep in flat_deps([ctx.attr.app]):
        lib_info = dep[ErlangAppInfo]
        for src in lib_info.beam:
            if src.is_directory:
                archive_path = path_join(lib_info.app_name, "ebin")
            else:
                archive_path = path_join(lib_info.app_name, "ebin", src.basename)
            if archive_path in entries:
                fail("Duplicate entry for %s: '%s'" % (src, archive_path))
            entries[archive_path] = src
        for src in ([] if ctx.attr.drop_hrl else lib_info.include) + lib_info.priv:
            rp = additional_file_dest_relative_path(dep.label, src)
            archive_path = path_join(lib_info.app_name, rp)
            if archive_path in entries:
                fail("Duplicate entry for %s: '%s'" % (src, archive_path))
            entries[archive_path] = src

    commands = ["set -euo pipefail"]
    for dest, src in entries.items():
        full_dest = path_join(contents_dir.path, dest)
        commands.append('mkdir -p $(dirname "{}")'.format(full_dest))
        if src.is_directory:
            commands.append('mkdir -p "{dest}" && cp -r "{src}"/* "{dest}"'.format(
                src = src.path,
                dest = full_dest,
            ))
        else:
            commands.append('cp "{src}" "{dest}"'.format(
                src = src.path,
                dest = full_dest,
            ))

    ctx.actions.run_shell(
        inputs = entries.values(),
        outputs = [contents_dir],
        command = "\n".join(commands),
    )

    (erlang_home, _, runfiles) = erlang_dirs(ctx)

    script = """set -euo pipefail

{maybe_install_erlang}

"{erlang_home}"/bin/erl \\
    -noshell \\
    -eval 'io:format("Assembling {name} escript...~n", []),
ContentsDir = "{contents_dir}",
Entries = filelib:fold_files(
    ContentsDir, "", true,
    fun(Path, Entries) ->
        {{ok, Bin}} = file:read_file(Path),
        Rel = string:prefix(Path, ContentsDir ++ "/"),
        Dest = case {flat} of
                    true ->
                        filename:basename(Path);
                    false ->
                        Rel
               end,
        [{{Dest, Rel, Bin}} | Entries]
    end, []),
UniqueEntries = lists:foldr(
    fun ({{Dest, Rel, Bin}}, Acc) ->
        case Acc of
            #{{Dest := _}} ->
                io:format("   dropping ~s (conflicting entry at ~s)~n", [Rel, Dest]),
                halt(1);
            _ ->
                Acc#{{Dest => Bin}}
        end
    end, #{{}}, Entries),
ArchiveEntries = maps:to_list(UniqueEntries),
ok = escript:create("{output}",
                    [{headers}
                     {{archive, ArchiveEntries, []}}]),
io:format("done.~n", []),
halt().
'
""".format(
        maybe_install_erlang = maybe_install_erlang(ctx),
        erlang_home = erlang_home,
        contents_dir = contents_dir.path,
        name = name,
        flat = str(ctx.attr.flat).lower(),
        headers = "".join(["{}, ".format(h) for h in ctx.attr.headers]),
        output = output.path,
    )

    inputs = depset(
        direct = [contents_dir],
        transitive = [runfiles.files],
    )

    ctx.actions.run_shell(
        inputs = inputs,
        outputs = [output],
        command = script,
    )

    return [
        DefaultInfo(
            executable = output,
            runfiles = runfiles,
        ),
    ]

escript_archive = rule(
    implementation = _impl,
    attrs = {
        "out": attr.string(),
        "headers": attr.string_list(
            default = DEFAULT_HEADERS,
        ),
        "srcs": attr.label_list(allow_files = [".erl"]),
        "hdrs": attr.label_list(allow_files = [".hrl"]),
        "beam": attr.label_list(allow_files = [".beam"]),
        "app": attr.label(providers = [ErlangAppInfo]),
        "flat": attr.bool(),
        "drop_hrl": attr.bool(),
    },
    toolchains = ["//tools:toolchain_type"],
    executable = True,
)
