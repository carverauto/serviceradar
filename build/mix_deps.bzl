"""Fetch and compile the Hex dependency tree as its own lockfile-keyed Bazel action.

Why this exists
---------------
//elixir/web-ng:precommit_check runs `mix precommit_fast`, which is three source-level lint
tasks. Before this rule, the single action that ran them also did `mix deps.get` for 171 Hex
packages, compiled all of them, compiled the first-party path dependencies, and built four
Rustler NIFs through cargo. That was 503s of a 600s CI job, and it was paid *in full on every
source change*, because Bazel caches an action all-or-nothing and that action's inputs
included every Elixir source in the tree.

Splitting the dependency work out gives Bazel something it can actually cache. This action's
inputs are mix.exs, mix.lock and config/** for the project and its path dependencies -- files
that change when dependencies change and not otherwise -- so on a normal PR it is a remote
cache hit and the entire fetch-and-compile disappears.

Note this is the opposite of the /cache side channel in //build:mix_release.bzl, which parks
state in a hostPath directory outside Bazel's model to buy back the incrementality a coarse
action threw away. Here the reuse comes from Bazel's own remote cache, keyed on content, and
is shared across the executor fleet rather than being local to whichever machine ran last.

What lands in the cache, and what does not
------------------------------------------
Hex packages, plus the three *vendored* path dependencies: connection, elixir_uuid and
opentelemetry_oban. Those three are local overrides of Hex packages (`override: true` in
mix.exs), and Hex packages compile against them -- `gnat` does `use Connection`, so
:connection has to be compiled first or the tree does not build at all. They are ~30 files of
third-party source that change on the order of never, so folding them in costs nothing in
cache hit rate.

The first-party path dependencies -- serviceradar_core, serviceradar_srql, datasvc -- stay
out. They churn with every PR, and compiling them is the honest per-change cost that remains
in the lint action.

Why the work directory is a fixed path
--------------------------------------
Elixir records absolute source paths in the `_build/<env>/lib/<app>/.mix/compile.*` manifests
it uses for staleness checks. If this action tars up a `_build` produced under one path and
the consuming action unpacks it under another, Mix sees every manifest path as missing and
recompiles the dependency tree -- which would defeat the entire point. So both actions build
under the same `$TMPDIR/<workdir_key>` path. This is not a cache: the directory is wiped at
the start of every action and nothing is read from a previous run. It exists only so the
paths inside the tarball resolve on the far side.
"""

def _stage_cmds(dirs):
    cmds = []
    for d in dirs:
        parent = d.rpartition("/")[0] or "."
        cmds.append(
            'mkdir -p "$WORKDIR/{parent}"\ncopy_dir "$EXECROOT/{dir}/" "$WORKDIR/{dir}/"\n'.format(
                dir = d,
                parent = parent,
            ),
        )
    return "".join(cmds)

def _mix_deps_impl(ctx):
    toolchain = ctx.toolchains["@rules_elixir//:toolchain_type"]
    otp = toolchain.otpinfo
    elixir = toolchain.elixirinfo

    erlang_home = otp.erlang_home
    otp_tar = getattr(otp, "release_dir_tar", None)

    # short_path for tree artifacts, so the sandbox symlink forest resolves the binaries.
    elixir_home = elixir.elixir_home or elixir.release_dir.short_path

    out = ctx.outputs.out

    direct_inputs = [otp.version_file, elixir.version_file] + ctx.files.srcs + ctx.files.extra_dir_srcs
    if otp_tar:
        direct_inputs.append(otp_tar)
    if getattr(elixir, "release_dir", None):
        direct_inputs.append(elixir.release_dir)
    if ctx.file.hex_cache:
        direct_inputs.append(ctx.file.hex_cache)
    if ctx.file.patches:
        direct_inputs.append(ctx.file.patches)
    if ctx.file.base_cache:
        direct_inputs.append(ctx.file.base_cache)

    ctx.actions.run_shell(
        mnemonic = "MixDeps",
        inputs = depset(direct = direct_inputs),
        outputs = [out],
        progress_message = "mix deps.get + deps.compile ({})".format(ctx.label.name),
        command = """
set -euo pipefail

EXECROOT=$PWD
OUT="$EXECROOT/{out}"
mkdir -p "$(dirname "$OUT")"

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

# Fixed path, wiped first -- see the "Why the work directory is a fixed path" note above.
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

# Set identically in the consuming lint action. Nothing compiled here has a Rustler NIF, so
# this changes no output -- but config/config.exs branches on it, and Mix treats a change in
# evaluated root config as a reason to recompile dependencies. Keeping the two actions'
# config evaluation identical is what stops the unpacked tree from being seen as stale.
export SERVICERADAR_SKIP_NIF_COMPILATION=1

export PATH="$ELIXIR_HOME/bin:$ERLANG_HOME/bin:$PATH"

copy_dir() {{
  local src="$1"
  local dest="$2"
  mkdir -p "$dest"
  local -a excludes=(
    "--exclude=.git"
    "--exclude=_build"
    "--exclude=deps"
    "--exclude=node_modules"
    "--exclude=target"
    "--exclude=tmp"
  )
  if command -v rsync >/dev/null 2>&1; then
    rsync -aL "${{excludes[@]}}" "$src" "$dest"
  else
    tar -C "${{src%/}}" -cf - "${{excludes[@]}}" . | tar -C "$dest" -xf -
  fi
}}

mkdir -p "$WORKDIR/{src_parent}"
copy_dir "$EXECROOT/{src_dir}/" "$WORKDIR/{src_dir}/"
{extra_copy}
chmod -R u+w "$WORKDIR"

# Bazel restages sources with fresh mtimes on every action, and Mix decides whether a path
# dependency needs recompiling by comparing source mtimes against its compile manifest. Left
# alone that makes each layer recompile everything the layer below just built -- which would
# defeat the whole point of stacking these caches. Real change detection here is Bazel's cache
# key: if a source actually changed, this action re-runs and produces a new tarball. So
# pinning mtimes to a fixed epoch is safe, and it must happen *before* a base cache is
# unpacked so the manifests inside it stay newer than the sources they describe.
find "$WORKDIR" -exec touch -t 200001010000 {{}} + 2>/dev/null || true

if [ -n "{base_cache}" ] && [ -f "$EXECROOT/{base_cache}" ]; then
  tar -xzf "$EXECROOT/{base_cache}" -C "$WORKDIR"
fi

cd "$WORKDIR/{src_dir}"

if [ -n "{hex_cache_tar}" ] && [ -f "$EXECROOT/{hex_cache_tar}" ]; then
  case "{hex_cache_tar}" in
    *.tar.gz|*.tgz) tar -xzf "$EXECROOT/{hex_cache_tar}" -C "$HOME" ;;
    *) tar -xf "$EXECROOT/{hex_cache_tar}" -C "$HOME" ;;
  esac
fi

if [ ! -d "$MIX_HOME/archives" ]; then
  mix local.hex --force
  mix local.rebar --force
fi

mix deps.get

# Third-party warning fixes, applied here rather than in the consuming lint action: they
# rewrite files under deps/, and doing that after unpacking the tarball would bump mtimes and
# make Mix recompile the tree the tarball exists to avoid.
if [ -n "{patches}" ] && [ -f "$EXECROOT/{patches}" ]; then
  python3 "$EXECROOT/{patches}" "$WORKDIR/{src_dir}"
fi

HEX_DEPS=""
if {compile_hex_deps}; then
  # Ask Mix which dependencies are Hex packages *in this MIX_ENV*, rather than reading
  # mix.lock keys: the lock also carries env-scoped entries (jump_credo_checks is :dev only),
  # and naming one that is not loaded in this env makes `mix deps.compile` fail outright with
  # "Unknown dependency ... for environment". Path dependencies do not print "(Hex package)",
  # so this list excludes them by construction.
  HEX_DEPS=$(mix deps | sed 's/\\x1b\\[[0-9;]*m//g' | grep '(Hex package)' | awk '{{print $2}}' | tr '\\n' ' ')
  if [ -z "$HEX_DEPS" ]; then
    echo "ERROR: derived an empty Hex dependency list from 'mix deps'" >&2
    exit 1
  fi
  echo "compiling $(echo $HEX_DEPS | wc -w) hex deps"
fi
echo "compiling named deps: {compile_deps}"

mix deps.compile {compile_deps} $HEX_DEPS

# Packed relative to $WORKDIR so the consuming action can unpack with a single -C and land
# every path where it was built. _home/.mix carries the Hex archive and the rebar3 binary and
# _home/.hex the registry cache (~26M), so the lint action needs neither `mix local.hex` nor
# any network round trip of its own.
cd "$WORKDIR"
tar -czf "$OUT" "{src_dir}/deps" "{src_dir}/_build" _home/.mix _home/.hex
""".format(
            out = out.path,
            elixir_home = elixir_home,
            erlang_home = erlang_home,
            otp_tar = otp_tar.path if otp_tar else "",
            workdir_key = ctx.attr.workdir_key,
            mix_env = ctx.attr.mix_env,
            src_dir = ctx.attr.src_dir,
            src_parent = ctx.attr.src_dir.rpartition("/")[0] or ".",
            extra_copy = _stage_cmds(ctx.attr.extra_dirs),
            hex_cache_tar = ctx.file.hex_cache.path if ctx.file.hex_cache else "",
            patches = ctx.file.patches.path if ctx.file.patches else "",
            base_cache = ctx.file.base_cache.path if ctx.file.base_cache else "",
            compile_hex_deps = "true" if ctx.attr.compile_hex_deps else "false",
            compile_deps = " ".join(ctx.attr.compile_deps),
        ),
        use_default_shell_env = False,
    )

    return [DefaultInfo(files = depset([out]))]

mix_deps = rule(
    implementation = _mix_deps_impl,
    attrs = {
        "srcs": attr.label_list(
            allow_files = True,
            doc = "Bootstrap files for the project itself (mix.exs, mix.lock, config/**)",
        ),
        "src_dir": attr.string(
            mandatory = True,
            doc = "Workspace-relative path to the Mix project root",
        ),
        "extra_dirs": attr.string_list(
            doc = "Workspace-relative directories to stage alongside the project",
        ),
        "extra_dir_srcs": attr.label_list(
            allow_files = True,
            doc = "File inputs backing extra_dirs. Use :deps_srcs for first-party path " +
                  "dependencies so this action stays keyed on lockfiles, and :srcs only " +
                  "for vendored path dependencies that Hex packages compile against.",
        ),
        "compile_deps": attr.string_list(
            doc = "App names to compile explicitly, alongside the Hex tree when " +
                  "compile_hex_deps is set. Path dependencies must be named here; they " +
                  "never appear in the derived Hex list.",
        ),
        "compile_hex_deps": attr.bool(
            default = True,
            doc = "Derive the Hex dependency list from `mix deps` and compile it. Set False " +
                  "for a layer stacked on a base_cache that already contains it.",
        ),
        "base_cache": attr.label(
            allow_single_file = True,
            doc = "Tarball from a lower mix_deps layer, unpacked before compiling. Lets a " +
                  "cheap-to-invalidate layer (first-party path deps) stack on an expensive " +
                  "but stable one (the Hex tree) without rebuilding it.",
        ),
        "workdir_key": attr.string(
            mandatory = True,
            doc = "Fixed work directory name, shared with the consuming mix_precommit so " +
                  "the absolute paths in _build manifests resolve after unpacking",
        ),
        "mix_env": attr.string(default = "test"),
        "hex_cache": attr.label(
            allow_single_file = True,
            doc = "Optional tarball pre-seeding the Hex/Mix cache",
        ),
        "patches": attr.label(
            allow_single_file = True,
            doc = "Optional python script applying third-party dependency patches",
        ),
        "out": attr.output(mandatory = True, doc = "Tarball of deps/ and _build/"),
    },
    toolchains = ["@rules_elixir//:toolchain_type"],
)
