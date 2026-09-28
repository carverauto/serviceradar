"""`mix format --check-formatted` and `mix credo --strict`, hermetically, on RBE.

CI's "Elixir Quality (<project>)" job runs `scripts/elixir_quality.sh --lint-only` for every
Mix project: `mix deps.get`, then `mix format --check-formatted` and `mix credo --strict`, with
MIX_ENV unset (so `dev`). A worktree without a Hex `deps/` tree cannot run either command, and a
`deps/` borrowed from another checkout carries whatever Styler that checkout resolved, so a
change can pass locally and still fail the job. These rules run the same two commands against the
same `.formatter.exs` and `.credo.exs`, with every Mix input supplied by Bazel:

  * the formatter plugins, Credo and its extra checks are Bazel-built `ErlangAppInfo` apps at the
    versions of the workspace Hex closure (//third_party/hex), linked into `_build/dev/lib` the way
    `mix_app` links a project's dependencies, so `mix loadpaths --no-deps-check` puts them on the
    code path without fetching anything;
  * `import_deps` needs only each named dependency's own `.formatter.exs`, so that one file is
    staged at `deps/<app>/.formatter.exs` -- the path `Mix.Project.deps_paths/0` reports for it;
  * a dependency whose source a config reads directly (Credo's `requires:` names
    `deps/ex_dna/lib/ex_dna/integrations/credo.ex`) is staged in full;
  * Hex is installed from @hex//:archive, the same archive `mix_app` installs, so Mix can resolve
    the project's Hex dependencies with HEX_OFFLINE=1.

`mix format` loads its plugins by running `mix loadpaths`, which would check dependency status and
fail on the unfetched ones. Running `loadpaths --no-deps-check` first, in the same `mix do`, makes
that later call a no-op -- Mix runs a task once per invocation.

Two rules share one script:

  * `elixir_quality_test` is the check. It fails on the first unformatted file or Credo issue and
    prints the formatter's diff.
  * `elixir_formatted_tree` runs `mix format` as a build action and emits the formatted inputs as a
    tree artifact. `//build/elixir_quality:apply` copies the files that changed back into the
    workspace, so fixing formatting needs no local Erlang or Mix either.
"""

load(
    "@rules_elixir//private:elixir_toolchain.bzl",
    "elixir_dirs",
    "erlang_dirs",
    "erlang_preamble",
)
load("@rules_erlang//:erlang_app_info.bzl", "ErlangAppInfo", "flat_deps")
load("@rules_erlang//:util.bzl", "path_join")
load(
    "@rules_erlang//private:util.bzl",
    "additional_file_dest_relative_path",
    "erl_libs_contents",
)

_TOOLCHAIN = "@rules_elixir//:toolchain_type"

def _staged_path(f):
    # Workspace-relative, so ../ in a config (`Path.expand("../.credo.base.exs", __DIR__)`)
    # resolves exactly as it does in a checkout. External inputs never reach here: dependency
    # files are staged under deps/<app> by the loops below.
    return f.short_path

def _file_arg(ctx, f, is_test):
    return f.short_path if is_test else f.path

def _dep_stage_commands(ctx, is_test, root_var, project_dir):
    commands = []
    inputs = []
    seen = {}
    for dep in ctx.attr.formatter_deps:
        info = dep[ErlangAppInfo]
        for f in info.srcs:
            if f.is_directory or f.basename != ".formatter.exs":
                continue
            rel = additional_file_dest_relative_path(dep.label, f)
            if rel != ".formatter.exs":
                continue
            dest = path_join(project_dir, "deps", info.app_name, ".formatter.exs")
            if dest in seen:
                continue
            seen[dest] = True
            inputs.append(f)
            commands.append('mkdir -p "{root}/{dir}" && cp "{src}" "{root}/{dest}"'.format(
                root = root_var,
                dir = path_join(project_dir, "deps", info.app_name),
                src = _file_arg(ctx, f, is_test),
                dest = dest,
            ))
    for dep in ctx.attr.source_deps:
        info = dep[ErlangAppInfo]
        for f in info.srcs:
            if f.is_directory:
                continue
            rel = additional_file_dest_relative_path(dep.label, f)
            dest = path_join(project_dir, "deps", info.app_name, rel)
            if dest in seen:
                continue
            seen[dest] = True
            inputs.append(f)
            commands.append('mkdir -p "$(dirname "{root}/{dest}")" && cp "{src}" "{root}/{dest}"'.format(
                root = root_var,
                src = _file_arg(ctx, f, is_test),
                dest = dest,
            ))
    return commands, inputs

def _script(ctx, is_test, erl_libs_path, project_dir, stage_commands, mix_commands, epilogue):
    (erlang_home, _, _) = erlang_dirs(ctx, short_path = is_test)
    (elixir_home, _) = elixir_dirs(ctx, short_path = is_test)
    hex_archive = _file_arg(ctx, ctx.file._hex_archive, is_test)
    return """\
#!/usr/bin/env bash
set -eo pipefail

{erlang_preamble}
if [[ "{elixir_home}" == /* ]]; then
    ABS_ELIXIR_HOME="{elixir_home}"
else
    ABS_ELIXIR_HOME="$PWD/{elixir_home}"
fi
export PATH="$ABS_ELIXIR_HOME/bin:$ABS_ERLANG_HOME/bin:$PATH"
ORIGINAL_DIR="$PWD"
ERL_LIBS_DIR="$ORIGINAL_DIR/{erl_libs_path}"
HEX_ARCHIVE="$ORIGINAL_DIR/{hex_archive}"
# Every app the tools need, including children Mix never converges for an unfetched
# dependency (Credo's bunt, for one). Mix leaves ERL_LIBS alone, so the code server has them.
export ERL_LIBS="$ERL_LIBS_DIR"

{root_setup}

{stage_commands}

cd "$STAGE_ROOT/{project_dir}"

# Mix writes ~/.mix and ~/.hex; keep both inside the scratch tree.
export HOME="$STAGE_ROOT/.home"
mkdir -p "$HOME"
export MIX_ENV=dev
export HEX_OFFLINE=1
export ELIXIR_ERL_OPTIONS="+fnu"
# CI exports this for the lint-only path: nothing here loads a NIF, and without it the core
# project's Rustler configuration reaches for cargo.
export SERVICERADAR_SKIP_NIF_COMPILATION=1

mix archive.install --force "$HEX_ARCHIVE" >/dev/null

mkdir -p _build/dev/lib
for dep in "$ERL_LIBS_DIR"/*; do
    [ -e "$dep" ] || continue
    ln -sfn "$dep" "_build/dev/lib/$(basename "$dep")"
done

{mix_commands}
{epilogue}
""".format(
        erlang_preamble = erlang_preamble(ctx, short_path = is_test),
        elixir_home = elixir_home,
        erl_libs_path = erl_libs_path,
        hex_archive = hex_archive,
        root_setup = "STAGE_ROOT=\"${TEST_TMPDIR}/stage\"\nrm -rf \"$STAGE_ROOT\"\nmkdir -p \"$STAGE_ROOT\"" if is_test else "STAGE_ROOT=\"$(mktemp -d)\"\ntrap 'rm -rf \"$STAGE_ROOT\"' EXIT",
        stage_commands = "\n".join(stage_commands),
        project_dir = project_dir,
        mix_commands = mix_commands,
        epilogue = epilogue,
    )

_LOADPATHS = "loadpaths --no-deps-check --no-archives-check"

_CHECK_COMMANDS = """\
status=0
echo "==> mix format --check-formatted ({project_dir})"
if ! mix do {loadpaths} + format --check-formatted; then
    echo "FAILED: mix format --check-formatted. Fix with: bazel run --config=remote //{package}:format" >&2
    status=1
fi
{credo}
exit $status
"""

_CREDO_COMMANDS = """\
echo "==> mix credo --strict ({project_dir})"
if ! mix do {loadpaths} + credo --strict; then
    echo "FAILED: mix credo --strict" >&2
    status=1
fi
"""

def _common_attrs():
    return {
        "srcs": attr.label_list(
            allow_files = True,
            doc = "The project's formatter and Credo inputs, plus any config file they read.",
        ),
        "project_dir": attr.string(
            doc = "Workspace-relative Mix project directory. Defaults to the package.",
        ),
        "tool_deps": attr.label_list(
            providers = [ErlangAppInfo],
            doc = "Apps that must be on the code path: formatter plugins, Credo, Credo plugins.",
        ),
        "formatter_deps": attr.label_list(
            providers = [ErlangAppInfo],
            doc = "Apps named in an `import_deps`; only their .formatter.exs is staged.",
        ),
        "source_deps": attr.label_list(
            providers = [ErlangAppInfo],
            doc = "Apps whose full source a config reads from deps/<app>/.",
        ),
        "_hex_archive": attr.label(
            default = Label("@hex//:archive"),
            allow_single_file = True,
        ),
    }

def _project_dir(ctx):
    return ctx.attr.project_dir or ctx.label.package

def _test_impl(ctx):
    project_dir = _project_dir(ctx)
    erl_libs_dir = ctx.label.name + "_deps"
    erl_libs_files = erl_libs_contents(
        ctx,
        deps = flat_deps(ctx.attr.tool_deps),
        headers = False,
        dir = erl_libs_dir,
    )
    stage = [
        'mkdir -p "$(dirname "$STAGE_ROOT/{dst}")" && cp "{src}" "$STAGE_ROOT/{dst}"'.format(
            src = f.short_path,
            dst = _staged_path(f),
        )
        for f in ctx.files.srcs
    ]
    dep_commands, dep_inputs = _dep_stage_commands(ctx, True, "$STAGE_ROOT", project_dir)
    mix_commands = _CHECK_COMMANDS.format(
        project_dir = project_dir,
        package = ctx.label.package,
        loadpaths = _LOADPATHS,
        credo = _CREDO_COMMANDS.format(project_dir = project_dir, loadpaths = _LOADPATHS) if ctx.attr.credo else "",
    )
    script = _script(
        ctx,
        is_test = True,
        erl_libs_path = path_join(ctx.label.package, erl_libs_dir),
        project_dir = project_dir,
        stage_commands = stage + dep_commands,
        mix_commands = mix_commands,
        epilogue = "",
    )
    out = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.write(out, script, is_executable = True)

    (_, _, erlang_runfiles) = erlang_dirs(ctx, short_path = True)
    (_, elixir_runfiles) = elixir_dirs(ctx, short_path = True)
    runfiles = erlang_runfiles.merge(elixir_runfiles).merge(ctx.runfiles(
        ctx.files.srcs + erl_libs_files + dep_inputs + [ctx.file._hex_archive],
    ))
    return [DefaultInfo(executable = out, runfiles = runfiles)]

elixir_quality_test = rule(
    implementation = _test_impl,
    attrs = dict(_common_attrs(), credo = attr.bool(default = True)),
    toolchains = [_TOOLCHAIN],
    test = True,
)

def _tree_impl(ctx):
    project_dir = _project_dir(ctx)
    erl_libs_dir = ctx.label.name + "_deps"
    erl_libs_files = erl_libs_contents(
        ctx,
        deps = flat_deps(ctx.attr.tool_deps),
        headers = False,
        dir = erl_libs_dir,
    )
    out = ctx.actions.declare_directory(ctx.label.name)
    stage = [
        'mkdir -p "$(dirname "$STAGE_ROOT/{dst}")" && cp "{src}" "$STAGE_ROOT/{dst}"'.format(
            src = f.path,
            dst = _staged_path(f),
        )
        for f in ctx.files.srcs
    ]
    dep_commands, dep_inputs = _dep_stage_commands(ctx, False, "$STAGE_ROOT", project_dir)

    # Emit every project input, formatted or not, under its workspace-relative path; the apply
    # tool copies only the ones whose bytes differ from the checkout.
    epilogue = "\n".join([
        'mkdir -p "$(dirname "$OUT/{p}")" && cp "$STAGE_ROOT/{p}" "$OUT/{p}"'.format(p = _staged_path(f))
        for f in ctx.files.srcs
        if _staged_path(f).startswith(project_dir + "/")
    ])
    script = _script(
        ctx,
        is_test = False,
        erl_libs_path = path_join(ctx.bin_dir.path, ctx.label.package, erl_libs_dir),
        project_dir = project_dir,
        stage_commands = ['OUT="$ORIGINAL_DIR/{}"'.format(out.path)] + stage + dep_commands,
        mix_commands = "mix do {} + format".format(_LOADPATHS),
        epilogue = epilogue,
    )
    (_, erlang_release, _) = erlang_dirs(ctx)
    (_, elixir_runfiles) = elixir_dirs(ctx)
    inputs = depset(
        ctx.files.srcs + erl_libs_files + dep_inputs + [ctx.file._hex_archive] +
        ([erlang_release] if erlang_release else []),
        transitive = [elixir_runfiles.files],
    )
    ctx.actions.run_shell(
        inputs = inputs,
        outputs = [out],
        command = script,
        mnemonic = "MixFormat",
        progress_message = "mix format %{label}",
    )
    return [DefaultInfo(files = depset([out]))]

elixir_formatted_tree = rule(
    implementation = _tree_impl,
    attrs = _common_attrs(),
    toolchains = [_TOOLCHAIN],
)

# `bazel run` executes on the caller's machine, but the formatting must not: the Erlang toolchain
# for a macOS host is an OTP built from source. So the formatted trees are pinned to the remote
# executor platform, whatever the top-level --platforms, and only the pure-Go copy tool is built
# for the host.
def _to_rbe_impl(_settings, _attr):
    return {"//command_line_option:platforms": str(Label("//build/rbe:rbe_platform"))}

_to_rbe = transition(
    implementation = _to_rbe_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)

def _to_host_impl(_settings, _attr):
    return {"//command_line_option:platforms": "@platforms//host"}

_to_host = transition(
    implementation = _to_host_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)

def _single(target):
    return target[0] if type(target) == "list" else target

def _format_impl(ctx):
    apply = _single(ctx.attr._apply)
    tool = apply[DefaultInfo].files_to_run.executable
    exe = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.symlink(output = exe, target_file = tool, is_executable = True)
    trees = ctx.files.trees
    runfiles = ctx.runfiles(trees).merge(apply[DefaultInfo].default_runfiles)
    return [
        DefaultInfo(executable = exe, runfiles = runfiles),
        RunEnvironmentInfo(environment = {
            "ELIXIR_FORMATTED_TREES": ":".join([t.short_path for t in trees]),
        }),
    ]

elixir_format = rule(
    implementation = _format_impl,
    attrs = {
        "trees": attr.label_list(
            cfg = _to_rbe,
            doc = "elixir_formatted_tree targets whose output is copied into the workspace.",
        ),
        "_apply": attr.label(
            default = Label("//build/elixir_quality/apply"),
            cfg = _to_host,
            executable = True,
        ),
    },
    executable = True,
    doc = "Copies the files `mix format` changed back into the checkout. Run with `bazel run`.",
)

# The files `mix format` (via .formatter.exs `inputs`) and `mix credo` (via `included:`) read
# in every project here: `{mix,.formatter}.exs` plus config/, lib/ and test/. A project whose
# formatter or Credo config reaches further passes `extra_inputs`.
_DEFAULT_INPUTS = [
    "*.ex",
    "*.exs",
    "*.heex",
    "mix.lock",
    ".formatter.exs",
    ".credo.exs",
    "config/**/*.ex",
    "config/**/*.exs",
    "lib/**/*.ex",
    "lib/**/*.exs",
    "lib/**/*.heex",
    "test/**/*.ex",
    "test/**/*.exs",
    "test/**/*.heex",
]

# The shared Credo configuration every project's .credo.exs evaluates from `..`.
_SHARED_CREDO = [
    "//:elixir/.credo.base.exs",
    "//:elixir/.credo.ex_dna.exs",
    "//:elixir/.credo.ex_slop.exs",
    "//:elixir/.credo.jump_checks.exs",
]

def elixir_quality(
        tool_deps,
        formatter_deps = [],
        source_deps = [],
        extra_inputs = [],
        extra_srcs = [],
        credo = True,
        **kwargs):
    """Declares :quality_check, :formatted and :format for the Mix project in this package.

    `bazel test --config=remote //elixir/<project>:quality_check` is the check;
    `bazel run --config=remote //elixir/<project>:format` rewrites the files it would reject.

    Args:
      tool_deps: apps put on the code path. CI compiles every dependency before it lints, and
        both tools read loaded code -- Spark.Formatter asks `Ash.Resource.default_extensions/0`
        and keeps only loaded extensions, AshCredo's checks no-op without Ash -- so pass the
        project's full dependency list plus its dev-only linters, not just the plugins.
      formatter_deps: apps listed in an `import_deps` of any .formatter.exs in the project.
        A missing one fails the check loudly ("Unknown dependency ... given to :import_deps").
      source_deps: apps whose source a config reads from deps/<app>/ directly.
      extra_inputs: more globs, for a formatter `inputs` or Credo `included` beyond the default.
      extra_srcs: files from other packages a config reads (a Credo `requires:` across projects).
      credo: run `mix credo --strict` as well (every CI-linted project does).
      **kwargs: passed to the test (tags, size, ...).
    """
    srcs = native.glob(_DEFAULT_INPUTS + extra_inputs, allow_empty = True) + _SHARED_CREDO + extra_srcs

    # Projects pass their mix_app dependency lists plus the dev-only linters, which overlap.
    tools = []
    for dep in tool_deps:
        if dep not in tools:
            tools.append(dep)
    tool_deps = tools
    elixir_quality_test(
        name = "quality_check",
        srcs = srcs,
        tool_deps = tool_deps,
        formatter_deps = formatter_deps,
        source_deps = source_deps,
        credo = credo,
        **kwargs
    )
    elixir_formatted_tree(
        name = "formatted",
        srcs = srcs,
        tool_deps = tool_deps,
        formatter_deps = formatter_deps,
        source_deps = source_deps,
        tags = ["manual"],
    )
    elixir_format(
        name = "format",
        trees = [":formatted"],
        tags = ["manual"],
    )
