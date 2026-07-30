"""Compile a Mix package inside a single hermetic Bazel action.

Why this exists
---------------
`elixir_app` invokes `elixirc` directly from the execroot. That is fine for a
plain library, but a Hex package is a *Mix project*, and Mix guarantees things
`elixirc` does not:

  * the working directory is the package root, so compile-time
    `File.read!("README.md")` / `File.read!("lib/.../debugger.html.eex")` and
    `@external_resource` resolve;
  * `mix.exs` runs, so `elixirc_paths`, `:compilers`, and per-package compiler
    options take effect;
  * `Mix.Project` is available -- Ash calls it at compile time and dies with
    `GenServer.call(Mix.ProjectStack, ...)` without it.

Dependencies are *not* fetched here. They arrive as Bazel-built `ErlangAppInfo`
deps, are staged into an ERL_LIBS tree, and are symlinked into
`_build/$MIX_ENV/lib` so `--no-deps-check` is satisfied without network access.

Output is the compiled `ebin` plus `priv`, exposed as `ErlangAppInfo` for
downstream `elixir_app` / `ex_unit_test` / `erlang_app_info` consumers.

Derived from rabbitmq-server's `bazel/elixir/mix_archive_build.bzl` (MPL-2.0),
which solved this problem for `rabbitmq_cli`'s Hex dependencies before the
project dropped Bazel in March 2025. Two deliberate departures from upstream:

  * upstream runs `mix archive.build` and unzips the resulting `.ez`. Some
    packages refuse to be built as an archive at all (phoenix hard-errors with
    "You are trying to install phoenix as an archive"), and the `.ez` carries
    only `ebin`, silently dropping `priv`. We run `mix compile` and take
    `_build/$MIX_ENV/lib/<app>` directly.
  * headers are declared via `hdrs` and surfaced on `ErlangAppInfo.include`, so
    that a dependent's `-include_lib("app/include/foo.hrl")` resolves.
"""

load("@bazel_skylib//lib:shell.bzl", "shell")
load(
    "@rules_elixir//private:elixir_toolchain.bzl",
    "elixir_dirs",
    "erlang_dirs",
    "maybe_install_erlang",
)
load(
    "@rules_erlang//:erlang_app_info.bzl",
    "ErlangAppInfo",
    "flat_deps",
)
load("@rules_erlang//:util.bzl", "path_join")
load(
    "@rules_erlang//private:util.bzl",
    "additional_file_dest_relative_path",
    "erl_libs_contents",
)

def _impl(ctx):
    (erlang_home, _, erlang_runfiles) = erlang_dirs(ctx)
    (elixir_home, elixir_runfiles) = elixir_dirs(ctx)

    app_name = ctx.attr.app_name

    ebin = ctx.actions.declare_directory(path_join(app_name, "ebin"))
    priv = ctx.actions.declare_directory(path_join(app_name, "priv"))

    # Mix insists on writing into the project tree (_build, .mix). Give it a
    # declared directory of its own rather than letting it scribble anywhere.
    mix_invocation_dir = ctx.actions.declare_directory("{}_mix".format(ctx.label.name))

    erl_libs_dir = ctx.label.name + "_deps"

    erl_libs_files = erl_libs_contents(
        ctx,
        target_info = None,
        headers = True,
        dir = erl_libs_dir,
        deps = flat_deps(ctx.attr.deps),
        ez_deps = [],
        expand_ezs = False,
    )

    erl_libs_path = ""
    if len(erl_libs_files) > 0:
        erl_libs_path = path_join(
            ctx.bin_dir.path,
            ctx.label.workspace_root,
            ctx.label.package,
            erl_libs_dir,
        )

    # Sources are staged under their own package path, mirroring the workspace layout
    # inside the sandbox, and Mix then runs from this target's package directory. That
    # matters for first-party code that reads a file OUTSIDE its own package at compile
    # time: serviceradar_core does
    #   Path.expand("../../../../../addons/<x>/config.schema.json", __DIR__)
    # which only resolves if `addons/` sits at the same relative depth it does in the
    # repo. Flattening every src to the root of the invocation dir would put it one level
    # off, and the read would fail with a File.Error naming a path that does not exist.
    # For a Hex package (an external repo) the label package is "", so this is a no-op.
    copy_srcs_commands = []
    for src in ctx.attr.srcs:
        for src_file in src[DefaultInfo].files.to_list():
            dest = path_join(
                src.label.package,
                additional_file_dest_relative_path(src.label, src_file),
            )
            copy_srcs_commands.extend([
                'mkdir -p "$(dirname ${{MIX_INVOCATION_DIR}}/{dest})"'.format(dest = dest),
                'cp {flags}"{src}" "${{MIX_INVOCATION_DIR}}/{dest}"'.format(
                    flags = "-r " if src_file.is_directory else "",
                    src = src_file.path,
                    dest = dest,
                ),
            ])

    # Appended last so these win over anything config.exs imports for the env.
    extra_config_commands = ""
    if ctx.attr.extra_config:
        extra_config_commands = "\n".join([
            "mkdir -p config",
            "[ -f config/config.exs ] || echo 'import Config' > config/config.exs",
            "cat >> config/config.exs <<'__BAZEL_EXTRA_CONFIG__'",
        ] + ctx.attr.extra_config + [
            "__BAZEL_EXTRA_CONFIG__",
        ])

    script = """set -euo pipefail

{maybe_install_erlang}

if [ -n "{erl_libs_path}" ]; then
    export ERL_LIBS=$PWD/{erl_libs_path}
fi

if [[ "{elixir_home}" == /* ]]; then
    ABS_ELIXIR_HOME="{elixir_home}"
else
    ABS_ELIXIR_HOME=$PWD/{elixir_home}
fi

ABS_EBIN="$PWD/{ebin}"
ABS_PRIV="$PWD/{priv}"

export PATH="$ABS_ELIXIR_HOME"/bin:"{erlang_home}"/bin:${{PATH}}

export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"

MIX_INVOCATION_DIR="{mix_invocation_dir}"

{copy_srcs_commands}

ORIGINAL_DIR=$PWD
cd "${{MIX_INVOCATION_DIR}}/{project_dir}"

# HOME must live inside the sandbox: Mix writes ~/.mix and ~/.hex, and a stray
# write to the real home directory is exactly the non-hermeticity we are here
# to avoid.
export HOME="${{PWD}}"
export MIX_ENV={mix_env}
export ERL_COMPILER_OPTIONS=deterministic

# Every dependency is already a Bazel input. If a package ever reaches for the
# network, fail here rather than succeed on a developer's machine and then fail
# on a network-isolated RBE executor.
export HEX_OFFLINE=1

for archive in {archives}; do
    "${{ABS_ELIXIR_HOME}}"/bin/mix archive.install --force $ORIGINAL_DIR/$archive
done

if [[ -n "{erl_libs_path}" ]]; then
    mkdir -p _build/${{MIX_ENV}}/lib
    for dep in "$ERL_LIBS"/*; do
        ln -s $dep _build/${{MIX_ENV}}/lib
    done
fi

{extra_config_commands}

{setup}

"${{ABS_ELIXIR_HOME}}"/bin/mix compile --no-deps-check

# Do not assume _build/$MIX_ENV/lib/<app>: a project with
# `build_per_environment: false` in its mix.exs (db_connection is one) builds
# into _build/shared/lib/<app> instead. Locate the output rather than guess it.
# `find` does not descend into symlinks, so the deps we linked into _build above
# cannot match here.
BUILT_EBIN=$(find _build -type d -path "*/{app_name}/ebin" | head -1)
if [ -z "$BUILT_EBIN" ]; then
    echo "mix compile produced no ebin for {app_name}; _build contains:" >&2
    find _build -maxdepth 3 -type d >&2
    exit 1
fi
BUILT=$(dirname "$BUILT_EBIN")

# -L dereferences: Mix links <build>/<app>/priv at the project's priv directory
# rather than copying it.
cp -RL "$BUILT_EBIN"/. "$ABS_EBIN"/
if [ -d "$BUILT"/priv ]; then
    cp -RL "$BUILT"/priv/. "$ABS_PRIV"/
fi

# The _build symlinks we created point outside this directory, and Bazel
# rejects dangling symlinks in a declared output tree.
find . -type l -delete
""".format(
        maybe_install_erlang = maybe_install_erlang(ctx),
        erl_libs_path = erl_libs_path,
        erlang_home = erlang_home,
        elixir_home = elixir_home,
        mix_invocation_dir = mix_invocation_dir.path,
        project_dir = ctx.label.package,
        copy_srcs_commands = "\n".join(copy_srcs_commands),
        archives = " ".join([shell.quote(a.path) for a in ctx.files.archives]),
        mix_env = ctx.attr.mix_env,
        extra_config_commands = extra_config_commands,
        setup = ctx.attr.setup,
        app_name = app_name,
        ebin = ebin.path,
        priv = priv.path,
    )

    inputs = depset(
        direct = ctx.files.srcs,
        transitive = [
            erlang_runfiles.files,
            elixir_runfiles.files,
            depset(ctx.files.archives),
            depset(erl_libs_files),
        ],
    )

    ctx.actions.run_shell(
        inputs = inputs,
        outputs = [ebin, priv, mix_invocation_dir],
        command = script,
        mnemonic = "MIX",
        progress_message = "Compiling Mix package %s" % app_name,
    )

    deps = flat_deps(ctx.attr.deps)

    runfiles = ctx.runfiles([ebin, priv])
    for dep in ctx.attr.deps:
        runfiles = runfiles.merge(dep[DefaultInfo].default_runfiles)

    return [
        DefaultInfo(
            files = depset([ebin, priv]),
            runfiles = runfiles,
        ),
        ErlangAppInfo(
            app_name = app_name,
            extra_apps = ctx.attr.extra_apps,
            include = ctx.files.hdrs,
            beam = [ebin],
            priv = [priv],
            license_files = [],
            srcs = ctx.files.srcs,
            deps = deps,
        ),
    ]

mix_app = rule(
    implementation = _impl,
    attrs = {
        "app_name": attr.string(mandatory = True),
        "srcs": attr.label_list(mandatory = True, allow_files = True),
        # Public headers. Surfaced on ErlangAppInfo.include so a dependent's
        # -include_lib("<app>/include/foo.hrl") resolves.
        "hdrs": attr.label_list(allow_files = [".hrl"]),
        # Mix archives to install before compiling. Defaults to Hex, which is needed by
        # essentially every project: Mix refuses to start when it cannot resolve an SCM for
        # a dependency in mix.exs, even a :dev-only one it would never compile. Nothing is
        # fetched -- HEX_OFFLINE is set and deps come from Bazel.
        "archives": attr.label_list(
            allow_files = [".ez"],
            default = ["@hex//:archive"],
        ),
        "extra_apps": attr.string_list(),
        "setup": attr.string(),
        # Config lines appended to config/config.exs *inside the action*, i.e. to the
        # sandbox copy -- the checked-in file is never touched. This exists so a
        # build-system concern can be expressed in the build system instead of in
        # production config. The motivating case is Rustler: `use Rustler` reads
        # Application.compile_env(otp_app, __MODULE__) and merges it OVER the use-options
        # (rustler/lib/rustler/compiler/config.ex), so `skip_compilation?: true` set here
        # keeps cargo out of the Bazel action without changing what `mix release` does.
        "extra_config": attr.string_list(),
        "mix_env": attr.string(default = "prod"),
        "deps": attr.label_list(providers = [ErlangAppInfo]),
    },
    provides = [ErlangAppInfo],
    toolchains = ["@rules_elixir//:toolchain_type"],
)
