load("//:erlang_app_info.bzl", "ErlangAppInfo")
load("//:util.bzl", "path_join")
load(":util.bzl", "erl_libs_contents")
load(
    "//tools:erlang_toolchain.bzl",
    "erlang_dirs",
    "maybe_install_erlang",
)

def beam_file(ctx, src, dir):
    name = src.basename.replace(".erl", ".beam")
    return ctx.actions.declare_file(path_join(dir, name))

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

    erl_libs_files = erl_libs_contents(
        ctx,
        target_info = target,
        headers = True,
        dir = erl_libs_dir,
        deps = ctx.attr.deps,
        ez_deps = ctx.files.ez_deps,
    )

    # it would be nice to properly compute the path, but ctx.bin_dir.path
    # does not appear to be the whole prefix
    if len(erl_libs_files) > 0:
        (output_dir, _, _path) = erl_libs_files[0].path.partition(erl_libs_dir)
        if output_dir == "":
            fail("Could not compute the ERL_LIBS relative path from {}".format(
                erl_libs_files[0].path,
            ))
        erl_libs_path = path_join(output_dir.rstrip("/"), erl_libs_dir)
    else:
        erl_libs_path = ""

    beam_files = [beam_file(ctx, src, ctx.attr.dest) for src in ctx.files.srcs]

    dest_dir = beam_files[0].dirname

    include_args = []
    if package_dir != "":
        include_args.extend(["-I", package_dir])
    # Lets -include_lib("<app>/include/x.hrl") resolve against the staged ERL_LIBS
    # tree via epp's include-path fallback. Needed when <app> is the app currently
    # being compiled, since its ebin does not exist yet and code:lib_dir/1 fails.
    if erl_libs_path != "":
        include_args.extend(["-I", erl_libs_path])
    for dir in unique_dirnames(ctx.files.hdrs):
        include_args.extend(["-I", dir])

    pa_args = []
    for dir in unique_dirnames(ctx.files.beam):
        pa_args.extend(["-pa", dir])

    srcs = ctx.actions.args()
    srcs.add_all(ctx.files.srcs)

    (erlang_home, _, runfiles) = erlang_dirs(ctx)

    compile_first_path = ""
    compile_first = ctx.attr.compile_first
    if compile_first != None:
        compile_first_path = compile_first[DefaultInfo].files_to_run.executable.path
        runfiles = runfiles.merge(compile_first[DefaultInfo].default_runfiles)

    script = """set -euo pipefail

{maybe_install_erlang}

mkdir -p {dest_dir}

if [ -n "{erl_libs_path}" ]; then
    export ERL_LIBS={erl_libs_path}
fi

# use the compile_first escript to determine the first pass, if present
if [ -n "{compile_first}" ]; then
    FIRST=$("{erlang_home}"/bin/escript {compile_first} $@)
else
    FIRST=
fi

if [ -n "$FIRST" ]; then
    "{erlang_home}"/bin/erlc \\
        -v {include_args} {pa_args} \\
        -o {out_dir} {erlc_opts} \\
        $FIRST
    "{erlang_home}"/bin/erlc \\
        -v {include_args} {pa_args} -pa {out_dir} \\
        -o {out_dir} {erlc_opts} \\
        $@
else
    "{erlang_home}"/bin/erlc \\
        -v {include_args} {pa_args} \\
        -o {out_dir} {erlc_opts} \\
        $@
fi
    """.format(
        maybe_install_erlang = maybe_install_erlang(ctx),
        erlang_home = erlang_home,
        dest_dir = dest_dir,
        erl_libs_path = erl_libs_path,
        compile_first = compile_first_path,
        include_args = " ".join(include_args),
        pa_args = " ".join(pa_args),
        out_dir = dest_dir,
        erlc_opts = " ".join(["'{}'".format(opt) for opt in ctx.attr.erlc_opts]),
    )

    inputs = depset(
        direct = ctx.files.hdrs + ctx.files.srcs + ctx.files.beam + erl_libs_files,
        transitive = [runfiles.files],
    )

    ctx.actions.run_shell(
        inputs = inputs,
        outputs = beam_files,
        command = script,
        arguments = [srcs],
        mnemonic = "ERLC",
    )

    return [
        DefaultInfo(files = depset(beam_files)),
    ]

erlang_bytecode = rule(
    implementation = _impl,
    attrs = {
        "compile_first": attr.label(
            executable = True,
            # I would have thought this should be "exec", since this is run
            # in the execution environment. However, it's an ecript needing
            # beam, and "target" allows it to match the toolchains for this
            # rule.
            cfg = "target",
        ),
        "app_name": attr.string(),
        "hdrs": attr.label_list(
            allow_files = [".hrl"],
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
        "erlc_opts": attr.string_list(),
        "dest": attr.string(
            default = "ebin",
        ),
    },
    toolchains = ["//tools:toolchain_type"],
)
