"""Build a Mix archive (.ez) inside a single hermetic Bazel action.

`mix archive.build` is how Mix packages a project for `mix archive.install`,
which is the only way to supply Mix with something it needs *before* it can
resolve a project -- Hex itself being the case that matters. Without Hex
installed as an archive, Mix aborts with "Could not find an SCM for dependency"
on any `{:dep, "~> x.y"}` entry, even one it would never compile.

Why this exists
---------------
`elixir_app` invokes `elixirc` directly from the execroot. That is fine for a
plain library, but a Hex package is a *Mix project*, and Mix guarantees two
things `elixirc` does not:

  * the working directory is the package root, so compile-time
    `File.read!("README.md")` / `File.read!("lib/.../debugger.html.eex")` and
    `@external_resource` resolve;
  * `mix.exs` runs, so `elixirc_paths`, `:compilers`, and per-package compiler
    options take effect.

Packages that read files relative to the cwd at compile time (`sourceror`,
`plug`, and transitively `ash` / `spark` / `reactor`) cannot build without it.

Dependencies are *not* fetched here. They arrive as Bazel-built `ErlangAppInfo`
deps, are staged into an ERL_LIBS tree, and are symlinked into
`_build/$MIX_ENV/lib` so `--no-deps-check` is satisfied without network access.

Adapted from rabbitmq-server's `bazel/elixir/mix_archive_build.bzl` (MPL-2.0),
which solved this same problem for `rabbitmq_cli`'s Hex dependencies before the
project dropped Bazel in March 2025.
"""

load("@bazel_skylib//lib:shell.bzl", "shell")
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
load(
    ":elixir_toolchain.bzl",
    "elixir_dirs",
    "erlang_dirs",
    "maybe_install_erlang",
)

def _impl(ctx):
    (erlang_home, _, erlang_runfiles) = erlang_dirs(ctx)
    (elixir_home, elixir_runfiles) = elixir_dirs(ctx)

    out = ctx.actions.declare_file(ctx.attr.out.name)

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
        ez_deps = ctx.files.ez_deps,
        expand_ezs = True,
    )

    erl_libs_path = ""
    if len(erl_libs_files) > 0:
        erl_libs_path = path_join(
            ctx.bin_dir.path,
            ctx.label.workspace_root,
            ctx.label.package,
            erl_libs_dir,
        )

    copy_srcs_commands = []
    for src in ctx.attr.srcs:
        for src_file in src[DefaultInfo].files.to_list():
            dest = additional_file_dest_relative_path(src.label, src_file)
            copy_srcs_commands.extend([
                'mkdir -p "$(dirname ${{MIX_INVOCATION_DIR}}/{dest})"'.format(dest = dest),
                'cp {flags}"{src}" "${{MIX_INVOCATION_DIR}}/{dest}"'.format(
                    flags = "-r " if src_file.is_directory else "",
                    src = src_file.path,
                    dest = dest,
                ),
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

ABS_OUT_PATH="$PWD/{out}"

export PATH="$ABS_ELIXIR_HOME"/bin:"{erlang_home}"/bin:${{PATH}}

export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"

MIX_INVOCATION_DIR="{mix_invocation_dir}"

{copy_srcs_commands}

ORIGINAL_DIR=$PWD
cd "${{MIX_INVOCATION_DIR}}"

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

{setup}

"${{ABS_ELIXIR_HOME}}"/bin/mix archive.build \\
    --no-deps-check \\
    -o "${{ABS_OUT_PATH}}"

# The _build symlinks we just created point outside this directory, and Bazel
# rejects dangling symlinks in a declared output tree.
find . -type l -delete
""".format(
        maybe_install_erlang = maybe_install_erlang(ctx),
        erl_libs_path = erl_libs_path,
        erlang_home = erlang_home,
        elixir_home = elixir_home,
        mix_invocation_dir = mix_invocation_dir.path,
        copy_srcs_commands = "\n".join(copy_srcs_commands),
        archives = " ".join([shell.quote(a.path) for a in ctx.files.archives]),
        mix_env = ctx.attr.mix_env,
        setup = ctx.attr.setup,
        out = out.path,
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
        outputs = [out, mix_invocation_dir],
        command = script,
        mnemonic = "MIX",
        progress_message = "Compiling Mix package %s" % ctx.label.name,
    )

    return [DefaultInfo(files = depset([out]))]

mix_archive_build = rule(
    implementation = _impl,
    attrs = {
        "srcs": attr.label_list(mandatory = True, allow_files = True),
        "archives": attr.label_list(allow_files = [".ez"]),
        "setup": attr.string(),
        "mix_env": attr.string(default = "prod"),
        "ez_deps": attr.label_list(allow_files = [".ez"]),
        "deps": attr.label_list(providers = [ErlangAppInfo]),
        "out": attr.output(),
    },
    toolchains = ["//:toolchain_type"],
)
