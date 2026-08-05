load(
    "//:erlang_app_info.bzl",
    "ErlangAppInfo",
    "flat_deps",
)
load(
    "//:util.bzl",
    "path_join",
    "windows_path",
)
load(
    ":util.bzl",
    "erl_libs_contents",
    "to_erlang_string_list",
)
load(
    "//tools:erlang_toolchain.bzl",
    "erlang_dirs",
    "maybe_install_erlang",
)

def short_dirname(f):
    if f.is_directory:
        return f.short_path
    else:
        return f.short_path.rpartition("/")[0]

def invert_package(package):
    if package == "":
        return package
    parts = package.split("/")
    return "/".join([".." for p in parts])

def package_relative_dirnames(package, files):
    dirs = []
    for f in files:
        sd = short_dirname(f)
        if sd.startswith(package + "/"):
            rel = sd.removeprefix(package + "/")
        else:
            rel = path_join(invert_package(package), sd)
        if rel not in dirs:
            dirs.append(rel)
    return dirs

def _to_atom_list(atoms):
    return "[" + ",".join(["'%s'" % a for a in atoms]) + "]"

def _quote(string_list_term):
    return string_list_term.replace('"', '\\"')

def _impl(ctx):
    if ctx.attr.eunit_mods == [] and ctx.attr.target == None:
        fail("Either eunit_mods or target must be set")
    if ctx.attr.eunit_mods != [] and ctx.attr.target != None:
        fail("eunit_mods and target cannot be set simultaneously")

    deps = list(ctx.attr.deps)
    eunit_mods = list(ctx.attr.eunit_mods)
    if ctx.attr.target != None:
        lib_info = ctx.attr.target[ErlangAppInfo]
        deps.extend(lib_info.deps)
        deps.append(ctx.attr.target)
        for m in lib_info.beam:
            if m.extension == "beam":
                module_name = m.basename.removesuffix(".beam")
                if not module_name.endswith("_tests"):
                    eunit_mods.append(module_name)
        for s in ctx.files.compiled_suites:
            module_name = s.basename.removesuffix(".beam")
            if not module_name.endswith("_tests"):
                eunit_mods.append(module_name)

    erl_libs_dir = ctx.label.name + "_deps"

    erl_libs_files = erl_libs_contents(
        ctx,
        deps = deps,
        ez_deps = ctx.files.ez_deps,
        dir = erl_libs_dir,
    )

    package = ctx.label.package

    erl_libs_path = path_join(package, erl_libs_dir)

    pa_args = []
    for dir in package_relative_dirnames(package, ctx.files.compiled_suites):
        pa_args.extend(["-pa", dir])

    apps_ebin_dirs = []
    if ctx.configuration.coverage_enabled:
        for dep in deps:
            if dep.label.workspace_name == "":
                apps_ebin_dirs.append(path_join(
                    "$TEST_SRCDIR",
                    "$TEST_WORKSPACE",
                    erl_libs_path,
                    dep[ErlangAppInfo].app_name,
                    "ebin",
                ))

    (erlang_home, _, runfiles) = erlang_dirs(ctx)

    eunit_opts_term = "[" + ",".join(ctx.attr.eunit_opts) + "]"

    coverdata_to_lcov = ctx.attr.coverdata_to_lcov
    coverdata_to_lcov_path = coverdata_to_lcov[DefaultInfo].files_to_run.executable.short_path

    if not ctx.attr.is_windows:
        test_env_commands = []
        for k, v in ctx.attr.test_env.items():
            test_env_commands.append("export {}=\"{}\"".format(k, v))

        output = ctx.actions.declare_file(ctx.label.name)
        script = """\
#!/usr/bin/env bash
set -eo pipefail

{maybe_install_erlang}

export HOME=${{TEST_TMPDIR}}
if [ -n "{erl_libs_path}" ]; then
    export ERL_LIBS=$TEST_SRCDIR/$TEST_WORKSPACE/{erl_libs_path}
fi

{test_env}

if [ -n "{package}" ]; then
    cd {package}
fi

COVER_PRE=
COVER_POST=
if [ -n "${{COVERAGE}}" ]; then
    COVER_PRE="[case cover:compile_beam_directory(D) of {{error, _}} -> halt(1); _ -> ok end || D <- {apps_ebin_dirs_term}], "
    COVER_POST="cover:export(\\"${{COVERAGE_OUTPUT_FILE}}\\"), "
fi
set -x
"{erlang_home}"/bin/erl +A1 -noinput -boot no_dot_erlang \\
    {pa_args} {extra_args} \\
    -eval "${{COVER_PRE}}case eunit:test({eunit_mods_term},{eunit_opts_term}) of ok -> ok; error -> halt(2) end, ${{COVER_POST}}halt()."
set +x
if [ -n "${{COVERAGE}}" ]; then
    "{erlang_home}"/bin/escript $TEST_SRCDIR/$TEST_WORKSPACE/{coverdata_to_lcov} \\
        ${{COVERAGE_OUTPUT_FILE}} \\
        ${{COVERAGE_OUTPUT_FILE}} \\
        > ${{TEST_UNDECLARED_OUTPUTS_DIR}}/coverdata_to_lcov.log
fi
""".format(
            maybe_install_erlang = maybe_install_erlang(ctx, short_path = True),
            erlang_home = erlang_home,
            apps_ebin_dirs_term = _quote(to_erlang_string_list(apps_ebin_dirs)),
            erl_libs_path = erl_libs_path if len(erl_libs_files) > 0 else "",
            package = package,
            coverdata_to_lcov = coverdata_to_lcov_path,
            pa_args = " ".join(pa_args),
            extra_args = " ".join(ctx.attr.erl_extra_args),
            eunit_mods_term = _to_atom_list(eunit_mods),
            eunit_opts_term = eunit_opts_term,
            test_env = "\n".join(test_env_commands),
        )
    else:
        test_env_commands = []
        for k, v in ctx.attr.test_env.items():
            test_env_commands.append("set {}={}".format(k, v))

        output = ctx.actions.declare_file(ctx.label.name + ".bat")
        script = """@echo off
if [{erl_libs_path}] == [] goto :env
REM TEST_SRCDIR is provided by bazel but with unix directory separators
set ERL_LIBS=%TEST_SRCDIR%/%TEST_WORKSPACE%/{erl_libs_path}
set ERL_LIBS=%ERL_LIBS:/=\\%
:env

{test_env}

if NOT [{package}] == [] cd {package}

echo on
"{erlang_home}\\bin\\erl" +A1 -noinput -boot no_dot_erlang ^
    {pa_args} {extra_args} ^
    -eval "case eunit:test({eunit_mods_term},{eunit_opts_term}) of ok -> ok; error -> halt(2) end, halt()" || exit /b 1
""".format(
            package = package,
            erlang_home = windows_path(erlang_home),
            erl_libs_path = erl_libs_path if len(erl_libs_files) > 0 else "",
            pa_args = " ".join(pa_args),
            extra_args = " ".join(ctx.attr.erl_extra_args),
            eunit_mods_term = _to_atom_list(eunit_mods),
            eunit_opts_term = eunit_opts_term,
            test_env = "\n".join(test_env_commands),
        ).replace("\n", "\r\n")

    ctx.actions.write(
        output = output,
        content = script,
    )

    runfiles = runfiles.merge_all(
        [ctx.runfiles(
            files = ctx.files.compiled_suites + ctx.files.data,
            transitive_files = depset(erl_libs_files),
        )] + ([coverdata_to_lcov[DefaultInfo].default_runfiles] if ctx.configuration.coverage_enabled else []) + [
            tool[DefaultInfo].default_runfiles
            for tool in ctx.attr.tools
        ],
    )
    if ctx.attr.target != None:
        runfiles = runfiles.merge(ctx.attr.target[DefaultInfo].default_runfiles)

    return [DefaultInfo(
        runfiles = runfiles,
        executable = output,
    )]

eunit_test = rule(
    implementation = _impl,
    attrs = {
        "coverdata_to_lcov": attr.label(
            executable = True,
            cfg = "target",
        ),
        "is_windows": attr.bool(mandatory = True),
        "compiled_suites": attr.label_list(
            allow_files = [".beam"],
        ),
        "eunit_mods": attr.string_list(),
        "target": attr.label(providers = [ErlangAppInfo]),
        "erl_extra_args": attr.string_list(),
        "eunit_opts": attr.string_list(),
        "data": attr.label_list(allow_files = True),
        "deps": attr.label_list(providers = [ErlangAppInfo]),
        "ez_deps": attr.label_list(
            allow_files = [".ez"],
        ),
        "tools": attr.label_list(),
        "test_env": attr.string_dict(),
    },
    toolchains = ["//tools:toolchain_type"],
    test = True,
)
