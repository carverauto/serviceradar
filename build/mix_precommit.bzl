"""Run the web-ng precommit checks hermetically using the rules_elixir toolchain.

This exists to replace a host-toolchain escape hatch. The original implementation was an
`sh_test` tagged `local`/`no-remote`/`no-sandbox` whose script began with

    command -v mix   || exit 1
    command -v cargo || exit 1

so it could only ever run where somebody had installed Elixir and Rust by hand. That is why
it could not go to the executors: the RBE image is `FROM ubuntu:24.04` with no Erlang, no
Elixir, and no cargo -- deliberately, because Bazel provides those toolchains.

So this rule takes OTP and Elixir from `@rules_elixir//:toolchain_type`, declared as action
inputs. Nothing is read from $PATH that Bazel did not put there.

Scope: what this action actually has to do
------------------------------------------
`mix precommit_fast` is

    ["deps.unlock --unused", "format --check-formatted", "credo"]

-- three source-level checks. None of them compiles the project: `mix credo` declares
@requirements ["loadpaths"], not ["compile"]. What they do need is a compiled *dependency*
tree, and that now arrives prebuilt from //build:mix_deps.bzl as `deps_cache`, keyed on
lockfiles and therefore a remote cache hit on any change that does not touch dependencies.

Two things follow, and together they are why this action stopped taking ten minutes:

  * No cargo. The four Rustler NIFs are skipped via SERVICERADAR_SKIP_NIF_COMPILATION (see
    elixir/web-ng/config/config.exs), which sets Rustler's :skip_compilation? so it never even
    shells out to `cargo metadata`. A lint task never loads a NIF. That deletes the release
    mode cargo build, the crates.io index update, the rules_rust toolchain, and the rust/*
    source staging from this action's inputs.
  * No dependency build. Only the first-party path dependencies still compile here, which is
    the honest per-change cost.

It is a build ACTION producing a log, not a test, which is what makes it remotely cacheable --
an unchanged tree is a cache hit rather than a rebuild. //elixir/web-ng wraps it in a skylib
`build_test` so `bazel test //elixir/web-ng:precommit` still works.

There is deliberately no ${HOST_HOME}/.cache work directory and no /cache side channel of the
kind //build:mix_release.bzl uses. Reuse comes from Bazel's remote cache, keyed on content.
The one fixed path is WORKDIR itself, which must match the deps_cache producer's -- Elixir
records absolute source paths in its `_build/**/.mix/compile.*` manifests, so unpacking that
tarball anywhere else makes Mix recompile the whole tree (measured: 104s and 164 dependencies
rebuilt at a different path, versus 14s at the same one). The directory is wiped at the start
of every action; nothing carries over from a previous run.
"""

def _mix_precommit_impl(ctx):
    toolchain = ctx.toolchains["@rules_elixir//:toolchain_type"]

    otp = toolchain.otpinfo
    elixir = toolchain.elixirinfo

    erlang_home = otp.erlang_home
    otp_tar = getattr(otp, "release_dir_tar", None)

    # short_path for tree artifacts, so the sandbox symlink forest resolves the binaries.
    elixir_home = elixir.elixir_home or elixir.release_dir.short_path

    log_out = ctx.outputs.out

    direct_inputs = (
        [otp.version_file, elixir.version_file, ctx.file.deps_cache] +
        ctx.files.srcs +
        ctx.files.data +
        ctx.files.extra_dir_srcs
    )
    if otp_tar:
        direct_inputs.append(otp_tar)
    if getattr(elixir, "release_dir", None):
        direct_inputs.append(elixir.release_dir)

    extra_copy_cmds = []
    for d in ctx.attr.extra_dirs:
        parent = d.rpartition("/")[0] or "."
        extra_copy_cmds.append(
            'mkdir -p "$WORKDIR/{parent}"\ncopy_dir "$EXECROOT/{dir}/" "$WORKDIR/{dir}/"\n'.format(
                dir = d,
                parent = parent,
            ),
        )

    # `data` is declared as action inputs (so Bazel materializes the files in the
    # execroot), but unlike `srcs` / `extra_dirs` they were never copied into
    # WORKDIR. Credo configs under elixir/.credo.* are loaded via
    # Path.expand("../.credo.ex_slop.exs", __DIR__) from elixir/web-ng/.credo.exs
    # and must exist at $WORKDIR/elixir/.credo.*. Without this staging, mix credo
    # fails with Code.LoadError enoent on the shared config fragments.
    data_copy_cmds = []
    for f in ctx.files.data:
        if f.short_path.startswith("../"):
            continue
        dest = f.short_path
        parent = dest.rpartition("/")[0]
        if parent:
            data_copy_cmds.append('mkdir -p "$WORKDIR/{}"\n'.format(parent))
        data_copy_cmds.append(
            'cp -L "$EXECROOT/{src}" "$WORKDIR/{dest}"\n'.format(
                src = f.path,
                dest = dest,
            ),
        )
        # Some Mix tooling reads .tool-versions from the project root.
        if f.basename == ".tool-versions" and dest != ctx.attr.src_dir + "/.tool-versions":
            data_copy_cmds.append(
                'cp -L "$EXECROOT/{src}" "$WORKDIR/{src_dir}/.tool-versions"\n'.format(
                    src = f.path,
                    src_dir = ctx.attr.src_dir,
                ),
            )

    ctx.actions.run_shell(
        mnemonic = "MixPrecommit",
        inputs = depset(direct = direct_inputs),
        outputs = [log_out],
        progress_message = "mix {} ({})".format(ctx.attr.mix_task, ctx.label.name),
        command = """
set -euo pipefail

EXECROOT=$PWD
LOG="$EXECROOT/{log_out}"
mkdir -p "$(dirname "$LOG")"

# Everything below goes to the log as well as the console, so a remote failure is
# explicable from the cached output alone.
exec > >(tee "$LOG") 2>&1

ELIXIR_HOME_RAW="{elixir_home}"
ELIXIR_HOME=$(cd "$EXECROOT" && cd "$ELIXIR_HOME_RAW" && pwd)

if [ -n "{otp_tar}" ] && [ -f "{otp_tar}" ]; then
  OTP_ROOT=$(mktemp -d)
  tar -xf "{otp_tar}" -C "$OTP_ROOT"
  if [ -d "$OTP_ROOT/lib/erlang" ]; then
    ERLANG_HOME="$OTP_ROOT/lib/erlang"
  else
    ERLANG_HOME=$(find "$OTP_ROOT" -maxdepth 2 -type d -name erlang -print | head -n1 | xargs dirname)
  fi
else
  ERLANG_HOME="{erlang_home}"
fi

# Must match the deps_cache producer -- see the module docstring.
WORKDIR="${{TMPDIR:-/tmp}}/{workdir_key}"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

export HOME="$WORKDIR/_home"
export MIX_HOME="$HOME/.mix"
export HEX_HOME="$HOME/.hex"
export REBAR_BASE_DIR="$HOME/.cache/rebar3"
export MIX_ENV={mix_env}
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export ELIXIR_ERL_OPTIONS="+fnu"
export HEX_HTTP_CONCURRENCY="${{HEX_HTTP_CONCURRENCY:-8}}"
export HEX_HTTP_TIMEOUT="${{HEX_HTTP_TIMEOUT:-120}}"
mkdir -p "$HOME"

# Skips the four Rustler NIF builds; see elixir/web-ng/config/config.exs. Lint tasks never
# load a NIF, and this is what keeps cargo out of the action entirely.
export SERVICERADAR_SKIP_NIF_COMPILATION=1

export PATH="$ELIXIR_HOME/bin:$ERLANG_HOME/bin:$PATH"

echo "ERLANG_HOME=$ERLANG_HOME"
echo "ELIXIR_HOME=$ELIXIR_HOME"
command -v mix

copy_dir() {{
  local src="$1"
  local dest="$2"
  # rsync creates only the final path component, so a nested destination such as
  # $WORKDIR/elixir/web-ng fails with ENOENT unless the parents already exist.
  mkdir -p "$dest"
  local -a excludes=(
    "--exclude=.git"
    "--exclude=.elixir_ls"
    "--exclude=_build"
    "--exclude=deps"
    "--exclude=node_modules"
    "--exclude=target"
    "--exclude=erl_crash.dump"
    "--exclude=tmp"
  )
  if command -v rsync >/dev/null 2>&1; then
    # Bazel stages sources as symlinks; dereference so Mix writes stay in WORKDIR.
    rsync -aL "${{excludes[@]}}" "$src" "$dest"
  else
    tar -C "${{src%/}}" -cf - "${{excludes[@]}}" . | tar -C "$dest" -xf -
  fi
}}

mkdir -p "$WORKDIR/{src_parent}"
copy_dir "$EXECROOT/{src_dir}/" "$WORKDIR/{src_dir}/"
{extra_copy}
{data_copy}
chmod -R u+w "$WORKDIR"

# Bazel restages sources with fresh mtimes every run, and Mix recompiles a path dependency
# whose sources look newer than its compile manifest. Without this the unpacked tree would be
# rebuilt from scratch here and the caches upstream would buy nothing. Change detection is
# Bazel's cache key, not mtime -- a real source change re-runs the producing action -- so this
# is safe, and it has to happen before the tarball lands so its manifests stay newer.
find "$WORKDIR" -exec touch -t 200001010000 {{}} + 2>/dev/null || true

# Prebuilt dependency tree: deps/, _build/ and the Mix home, all at the paths they were
# built under. copy_dir excludes deps/_build, so this cannot clobber staged sources.
tar -xzf "$EXECROOT/{deps_cache}" -C "$WORKDIR"

cd "$WORKDIR/{src_dir}"

# Resolves the path dependencies against the unpacked tree. The Hex packages are already
# fetched and compiled, so this does not hit the network.
mix deps.get

mix {mix_task}
""".format(
            log_out = log_out.path,
            elixir_home = elixir_home,
            erlang_home = erlang_home,
            otp_tar = otp_tar.path if otp_tar else "",
            workdir_key = ctx.attr.workdir_key,
            mix_env = ctx.attr.mix_env,
            src_dir = ctx.attr.src_dir,
            src_parent = ctx.attr.src_dir.rpartition("/")[0] or ".",
            extra_copy = "".join(extra_copy_cmds),
            data_copy = "".join(data_copy_cmds),
            deps_cache = ctx.file.deps_cache.path,
            mix_task = ctx.attr.mix_task,
        ),
        use_default_shell_env = False,
    )

    return [DefaultInfo(files = depset([log_out]))]

mix_precommit = rule(
    implementation = _mix_precommit_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = True, doc = "Project sources"),
        "data": attr.label_list(
            allow_files = True,
            doc = "Additional files staged into WORKDIR at their short_path " +
                  "(e.g. shared elixir/.credo.* configs loaded by project .credo.exs)",
        ),
        "src_dir": attr.string(
            mandatory = True,
            doc = "Workspace-relative path to the Mix project root",
        ),
        "extra_dirs": attr.string_list(
            doc = "Workspace-relative directories to stage alongside the project (path deps)",
        ),
        "extra_dir_srcs": attr.label_list(
            allow_files = True,
            doc = "File inputs backing extra_dirs",
        ),
        "deps_cache": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "Tarball from //build:mix_deps.bzl holding the compiled dependency tree",
        ),
        "workdir_key": attr.string(
            mandatory = True,
            doc = "Fixed work directory name; must match the deps_cache producer so the " +
                  "absolute paths recorded in _build manifests resolve after unpacking",
        ),
        "mix_env": attr.string(default = "test"),
        "mix_task": attr.string(
            default = "precommit_fast",
            doc = "Mix task to run once dependencies are in place",
        ),
        "out": attr.output(mandatory = True, doc = "Log file produced by the run"),
    },
    toolchains = ["@rules_elixir//:toolchain_type"],
)
