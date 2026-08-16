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
load("@rules_cc//cc:action_names.bzl", "ACTION_NAMES")
load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain", "use_cc_toolchain")

# The full cc_common, not the restricted global of the same name -- the global exposes
# neither configure_features nor create_compile_variables.
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
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
load(
    "@rules_foreign_cc//foreign_cc/private:cc_toolchain_util.bzl",
    "absolutize_path_in_str",
)

# Emitted into the staged project when a package uses Bundlex. See the call site for why a
# lock is required at all. __GRAPH__ is replaced with an Elixir map of app => [children],
# built from the Bazel dependency graph; versions are read back from each application's own
# compiled .app so nothing is invented here.
#
# Checksums are left empty. They exist for lock verification, which `--no-deps-check`
# skips, and Bazel has already established provenance -- every one of these packages came
# from a `hex_archive` with a pinned sha256 in //MODULE.bazel.
_MIX_LOCK_SCRIPT = """
"${ABS_ELIXIR_HOME}"/bin/elixir -e '
  graph = __GRAPH__

  # ERL_LIBS is a colon-separated LIST of directories: most dependencies are referenced
  # where they were built rather than copied into one tree. Reading it as a single path
  # silently yields no version for every app, the `vsn != nil` guard below drops them all
  # from the lock, and Bundlex then fails with :unknown_application because
  # Mix.Project.deps_paths/0 is built from that lock.
  erl_libs = System.get_env("ERL_LIBS") || ""
  erl_libs_dirs = String.split(erl_libs, ":", trim: true)

  version = fn app ->
    name = Atom.to_string(app)

    Enum.find_value(erl_libs_dirs, fn dir ->
      app_file = Path.join([dir, name, "ebin", name <> ".app"])

      case :file.consult(String.to_charlist(app_file)) do
        {:ok, [{:application, _name, keys}]} ->
          case Keyword.get(keys, :vsn) do
            nil -> nil
            vsn -> to_string(vsn)
          end

        _ ->
          nil
      end
    end)
  end

  lock =
    for {app, children} <- graph, vsn = version.(app), vsn != nil, into: %{} do
      deps =
        for child <- children, child != :elixir, version.(child) != nil do
          {child, ">= 0.0.0", [hex: child, repo: "hexpm", optional: false]}
        end

      {app, {:hex, app, vsn, "", [:mix], deps, "hexpm", ""}}
    end

  File.write!("mix.lock", inspect(lock, limit: :infinity, printable_limit: :infinity) <> "\\n")
'
"""

def _nif_opt_transition_impl(_settings, _attr):
    return {"//command_line_option:compilation_mode": "opt"}

# Build NIFs optimised no matter what mode the rest of the build is in.
#
# `fastbuild` -- the default -- means `-C opt-level=0 -C debuginfo=2` for rules_rust, and
# the result ships straight into the release:
#
#     libsrql_nif.so                 60.6 MB -> 17.0 MB
#     libzen_nif.so                  49.3 MB -> 20.4 MB
#     libanomaly_disposition_nif.so   5.2 MB ->  0.7 MB
#
# 77 MB across every image, since serviceradar_core and serviceradar_srql are in all of
# them. `-c opt` on the command line would get the same bytes, but it is a whole-
# configuration flag: it would also change how every Go binary and Rust tool in the repo
# is built, and it only helps if whoever runs the build remembers to pass it.
#
# A transition scopes it to this one dependency edge instead. A NIF is dlopened into the
# BEAM and its failures surface as Erlang errors, not native stack traces, so there is
# nothing to gain from an unoptimised build of one.
#
# //build/transition.bzl uses the same mechanism for //command_line_option:platforms.
#
# Cost: crates reachable from a NIF are configured twice if something else depends on them
# in the default mode -- built once per configuration. That is the price of not forcing
# opt on the whole repo.
_nif_opt_transition = transition(
    implementation = _nif_opt_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:compilation_mode"],
)

# Extensions and filenames that mean "this package will invoke a C compiler".
#
# bundlex.exs is the Bundlex signal: `Bundlex.Project.load/1` only finds natives in a
# package that ships one, so a Membrane package without it compiles no C even though it
# depends on bundlex. Makefile/Makefile.* is the elixir_make signal (bcrypt_elixir, crc,
# lazy_html, ...), which shells out to make and picks up $CC from the environment.
_NATIVE_SOURCE_EXTENSIONS = ["c", "cc", "cpp", "cxx", "m"]
_NATIVE_BUILD_FILES = ["bundlex.exs", "Makefile"]

# Packages that keep the executor image's gcc instead of the hermetic toolchain.
#
# These resolve a system library through pkg-config, which reports only `-lssl -lcrypto`
# and leaves the header and library directories to the compiler's defaults. gcc has such
# defaults; the hermetic toolchain is invoked with `--sysroot=/dev/null -nostdlibinc` and
# deliberately has none, so ex_dtls fails with
#     dtls.h:3:10: fatal error: 'openssl/err.h' file not found
#     ld.lld: error: unable to find library -lssl
# Making these hermetic means giving them a hermetic OpenSSL rather than a hermetic
# compiler, which is a separate piece of work -- they are already tied to the image today,
# so keeping them on gcc changes nothing about their current guarantees.
#
# Both need OpenSSL: ex_dtls directly, ex_libsrt through libsrt. Their precompiled OS deps
# resolve fine either way -- ex_libsrt links -lsrt out of the staged archive -- so this is
# only about the two system libraries pkg-config leaves to the compiler's defaults.
_SYSTEM_CC_APPS = [
    "ex_dtls",
    "ex_libsrt",
]

def _erl_libs_entry(info):
    """The directory that makes `info` visible to ERL_LIBS, or None if it needs staging.

    ERL_LIBS is a colon-separated list of directories, each scanned for <app>/ebin. A dep
    whose compiled output already sits at <parent>/<app>/ebin can therefore be handed to
    Erlang as <parent>, with no copying at all.
    """
    if len(info.beam) != 1:
        return None
    ebin = info.beam[0]
    if not ebin.is_directory:
        return None
    suffix = "/{}/ebin".format(info.app_name)
    if not ebin.path.endswith(suffix):
        return None
    parent = ebin.path[:-len(suffix)]

    # priv has to be the sibling ERL_LIBS expects, or the app would lose it.
    for priv in info.priv:
        if priv.path != path_join(parent, info.app_name, "priv"):
            return None
    return parent

# The architecture a DOWNLOADED artefact has to match.
#
# A package that COMPILES native code learns the target from cc_env below -- that is why
# bcrypt_elixir and crc cross-compile correctly. A package that DOWNLOADS a prebuilt one
# had no equivalent signal, so it fell back to :erlang.system_info(:system_architecture),
# which is the EXECUTOR's triple, not the target's. Building for arm64 on an amd64 RBE
# executor then fetches an x86-64 .so that links, ships, and fails only at dlopen -- as
# ENOENT, for a file that is present. adbc, lazy_html and mdex_native all hit this.
#
# These are rustler_precompiled's documented cross-compilation override (added for
# Nerves); cc_precompiler reads TARGET_ARCH/OS/ABI and joins them itself. Exported for
# EVERY mix_app rather than only the native-compiling ones, because a downloading package
# ships no C sources and so never reaches the cc_env branch at all.
def _target_triple_env(ctx):
    if not ctx.target_platform_has_constraint(
        ctx.attr._os_linux[platform_common.ConstraintValueInfo],
    ):
        # Only linux targets are packaged into images; leave a host build alone.
        return {}

    arch = "aarch64" if ctx.target_platform_has_constraint(
        ctx.attr._cpu_aarch64[platform_common.ConstraintValueInfo],
    ) else "x86_64"

    return {
        "TARGET_ARCH": arch,
        "TARGET_VENDOR": "unknown",
        "TARGET_OS": "linux",
        "TARGET_ABI": "gnu",
    }

# Fail the build if a compiled package emitted a NIF for the wrong CPU.
#
# This is the guard that actually holds. The action cannot be network-isolated -- the RBE
# executor has to reach the BuildBuddy cache proxy -- so "forbid downloads" is unenforceable
# by construction. Checking the OUTPUT is enforceable, and depends on nobody's sandbox
# policy: a package may fetch whatever it likes, but it may not emit the wrong CPU.
#
# e_machine is a 2-byte little-endian field at offset 18 of every ELF header:
# 0x3e -> x86-64, 0xb7 -> aarch64. `od` is in coreutils, so this needs no new tool.
#
# Without this, a mismatched NIF links, ships and fails only at dlopen on the target host,
# where glibc reports it as ENOENT for a file that is present. That is how adbc, lazy_html
# and mdex_native each shipped an x86-64 .so inside a linux/arm64 image.
def _elf_arch_assertion(ctx):
    env = _target_triple_env(ctx)
    if not env:
        return ""

    want, want_name = ("b7", "aarch64") if env["TARGET_ARCH"] == "aarch64" else ("3e", "x86-64")

    return """
for so in $(find "$ABS_PRIV" -type f -name '*.so*' 2>/dev/null); do
    # Only real ELF objects, and only regular files. Two false positives found by running
    # the whole tree rather than one package: macOS-built tars carry AppleDouble "._name"
    # stubs that match *.so but are not ELF, and phoenix ships a DIRECTORY called
    # phx.gen.socket. `set -euo pipefail` is in force, so an unguarded od on either aborts
    # the action instead of skipping the entry.
    magic=$(od -An -tx1 -N4 "$so" 2>/dev/null | tr -d ' \n' || true)
    [ "$magic" = "7f454c46" ] || continue

    machine=$(od -An -tx1 -j18 -N1 "$so" 2>/dev/null | tr -d ' \n' || true)
    if [ -n "$machine" ] && [ "$machine" != "{want}" ]; then
        echo "ERROR: $(basename "$so") is not {want_name} (ELF e_machine 0x$machine)." >&2
        echo "  This package emitted or downloaded a NIF for the wrong CPU. It would link," >&2
        echo "  ship, and fail at dlopen on the target as a misleading ENOENT." >&2
        exit 1
    fi
done
""".format(want = want, want_name = want_name)

def _compiles_native_code(ctx):
    if ctx.attr.app_name in _SYSTEM_CC_APPS:
        return False
    for f in ctx.files.srcs:
        if f.extension in _NATIVE_SOURCE_EXTENSIONS:
            return True
        if f.basename in _NATIVE_BUILD_FILES or f.basename.startswith("Makefile."):
            return True
    return False

def _impl(ctx):
    (erlang_home, _, erlang_runfiles) = erlang_dirs(ctx)
    (elixir_home, elixir_runfiles) = elixir_dirs(ctx)

    app_name = ctx.attr.app_name

    # Scoped by TARGET name, not app name. Two targets in one package may compile the same
    # application in different envs -- :erlang_app (test, for ExUnit) and :erlang_app_prod
    # (for a release). Keying the output directory on app_name alone makes both declare
    # <app_name>/ebin and Bazel rejects the package with "generated by these conflicting
    # actions". The app name still determines the directory INSIDE an ERL_LIBS tree, which
    # is derived from ErlangAppInfo.app_name by erl_libs_contents, not from this path.
    ebin = ctx.actions.declare_directory(path_join(ctx.label.name, app_name, "ebin"))
    priv = ctx.actions.declare_directory(path_join(ctx.label.name, app_name, "priv"))

    # Mix insists on writing into the project tree (_build, .mix). Give it a
    # declared directory of its own rather than letting it scribble anywhere.
    # Only a package that ships bundlex.exs ever has this tree read back: the consumer loop
    # below stages the POST-COMPILE tree of its `bundlex_deps` to pick up Unifex-generated
    # headers, and selects those deps by looking for bundlex.exs in ErlangAppInfo.srcs --
    # which is ctx.files.srcs, exactly what is tested here.
    #
    # For everything else it is staging scratch nothing reads, and declaring it as an output
    # made Bazel capture and upload it to the CAS on every execution: ~241 MB across ~4000
    # files for serviceradar_core alone, twice over since that app builds in both test and
    # prod env. Undeclared, it goes to a temp dir the action deletes on exit.
    ships_bundlex = False
    for f in ctx.files.srcs:
        if f.basename == "bundlex.exs":
            ships_bundlex = True
            break

    mix_invocation_dir = None
    if ships_bundlex:
        mix_invocation_dir = ctx.actions.declare_directory("{}_mix".format(ctx.label.name))

    erl_libs_dir = ctx.label.name + "_deps"

    # Hand Erlang the dependencies' own output directories instead of copying them.
    #
    # erl_libs_contents merges every dependency into one private <target>_deps tree, and a
    # dependency whose ebin is a directory (every mix_app: see the declare_directory above)
    # is merged with a `cp -RL` run_shell action. That action is per CONSUMER, so one
    # dependency is copied once per package that depends on it -- measured on one build:
    # 88 copy actions for 14 distinct dependencies, bundlex copied 26 times and shmex 23,
    # every copy byte-identical, 908s in total and not one byte compiled. They cannot even
    # share a cache entry, because the output PATH is part of the action key.
    #
    # None of that merging is required: ERL_LIBS is a colon-separated list precisely so it
    # can name several directories, and mix_app already emits <target>/<app>/ebin, which is
    # the layout ERL_LIBS scans for. So the parent directory goes straight on the list.
    #
    # A dependency shipping .hrl files still has to be staged: -include_lib resolves the
    # application directory from the code path and expects include/ NEXT TO ebin/, while
    # mix_app publishes headers from `hdrs` instead of staging them into <app>/include.
    direct_entries = []
    direct_dep_files = []
    staged_deps = []
    for dep in flat_deps(ctx.attr.deps):
        info = dep[ErlangAppInfo]
        entry = _erl_libs_entry(info) if len(info.include) == 0 else None
        if entry == None:
            staged_deps.append(dep)
        else:
            if entry not in direct_entries:
                direct_entries.append(entry)
            direct_dep_files.extend(info.beam)
            direct_dep_files.extend(info.priv)

    erl_libs_files = erl_libs_contents(
        ctx,
        target_info = None,
        headers = True,
        dir = erl_libs_dir,
        deps = staged_deps,
        ez_deps = [],
        expand_ezs = False,
    )

    erl_libs_entries = []
    if len(erl_libs_files) > 0:
        erl_libs_entries.append(path_join(
            ctx.bin_dir.path,
            ctx.label.workspace_root,
            ctx.label.package,
            erl_libs_dir,
        ))
    erl_libs_entries.extend(direct_entries)

    # Absolute, because the action cds into the mix invocation directory before Mix reads it.
    erl_libs_path = ":".join(["$PWD/" + e for e in erl_libs_entries])

    # Sources are staged under their own package path, mirroring the workspace layout
    # inside the sandbox, and Mix then runs from this target's package directory. That
    # matters for first-party code that reads a file OUTSIDE its own package at compile
    # time: serviceradar_core does
    #   Path.expand("../../../../../addons/<x>/config.schema.json", __DIR__)
    # which only resolves if `addons/` sits at the same relative depth it does in the
    # repo. Flattening every src to the root of the invocation dir would put it one level
    # off, and the read would fail with a File.Error naming a path that does not exist.
    # For a Hex package (an external repo) the label package is "", so this is a no-op.
    # BATCHED BY DESTINATION DIRECTORY, which is a measured cost and not a micro-optimisation.
    #
    # This loop used to emit, per source file, `mkdir -p "$(dirname ...)"` followed by `cp`.
    # serviceradar_core stages 2242 files and web-ng 2663, so that was ~4500 and ~5300 process
    # spawns -- and the `$(dirname ...)` command substitution forks a subshell on top of each
    # mkdir. Timed inside the action:
    #
    #   SRDIAG serviceradar_core/test   stage_in_s=7
    #   SRDIAG serviceradar_web_ng/test stage_in_s=11
    #
    # entirely before `mix compile` starts, and paid four times over (each app is compiled in
    # both the test and prod env).
    #
    # Every path here is known at ANALYSIS time, so the grouping is done in Starlark and the
    # shell just runs it: one `mkdir -p` for all directories at once, then one `cp` per
    # destination directory rather than per file. ~200 directories instead of ~2500 files.
    #
    # `cp a b c destdir/` is POSIX, unlike GNU `cp -t`, so this stays correct on a developer's
    # macOS machine as well as the Linux executors.
    #
    # A file whose destination BASENAME differs from its source basename cannot join a batch
    # (the batch form preserves basenames), and neither can a TreeArtifact, which needs -r.
    # Both fall back to an individual cp. Directories are also emitted after the batches so a
    # recursive copy cannot race a batch writing into the same place.
    batched = {}
    individual = []
    dest_dirs = {}

    for src in ctx.attr.srcs:
        for src_file in src[DefaultInfo].files.to_list():
            dest = path_join(
                src.label.package,
                additional_file_dest_relative_path(src.label, src_file),
            )
            dest_dir = dest.rpartition("/")[0]
            dest_dirs[dest_dir] = True
            if src_file.is_directory or src_file.basename != dest.rpartition("/")[2]:
                individual.append((src_file, dest, src_file.is_directory))
            else:
                batched.setdefault(dest_dir, []).append(src_file.path)

    copy_srcs_commands = []

    # One mkdir for the whole tree. Chunked because a package with thousands of directories
    # would otherwise overflow ARG_MAX and fail with "Argument list too long".
    dirs = sorted([d for d in dest_dirs if d])
    for i in range(0, len(dirs), 400):
        copy_srcs_commands.append("mkdir -p {}".format(" ".join([
            '"${{MIX_INVOCATION_DIR}}/{}"'.format(d)
            for d in dirs[i:i + 400]
        ])))

    for dest_dir in sorted(batched):
        paths = batched[dest_dir]
        for i in range(0, len(paths), 400):
            copy_srcs_commands.append('cp {srcs} "${{MIX_INVOCATION_DIR}}/{dir}/"'.format(
                srcs = " ".join(['"{}"'.format(p) for p in paths[i:i + 400]]),
                dir = dest_dir,
            ))

    for src_file, dest, is_dir in individual:
        copy_srcs_commands.append('cp {flags}"{src}" "${{MIX_INVOCATION_DIR}}/{dest}"'.format(
            flags = "-r " if is_dir else "",
            src = src_file.path,
            dest = dest,
        ))

    # Bundlex reads its dependencies' SOURCE, not their compiled output.
    #
    # `Bundlex.Project.load/1` does Code.require_file("deps/<app>/bundlex.exs"), and
    # `Bundlex.Native.parse_app_libs/3` walks that for every dependency declaring native
    # libraries. ERL_LIBS carries ebin and priv only, so a package like shmex dies with
    #     ** (Code.LoadError) could not load .../deps/bunch_native/bundlex.exs
    # and the whole Membrane stack under it is unbuildable -- which is why
    # //elixir/serviceradar_core_elx had no mix_app and stayed on the non-hermetic
    # mix_release path.
    #
    # Detected rather than declared: a package needs this exactly when it depends on
    # bundlex, and that is already visible in the graph. Making it an attribute would mean
    # hand-maintaining a list across the 55 generated third_party/hex BUILD files.
    #
    # Sources are staged, not fetched -- every file here is an existing Bazel input from
    # the dependency's own filegroup, so the action stays hermetic.
    all_deps = flat_deps(ctx.attr.deps)
    uses_bundlex = False
    for dep in all_deps:
        if dep[ErlangAppInfo].app_name == "bundlex":
            uses_bundlex = True

    # The hermetic C compiler, given ONLY to the packages that actually run one.
    #
    # Scoped deliberately. Exporting CC/CFLAGS from every mix_app would put the whole clang
    # toolchain in 271 packages' action inputs and rekey all of them on every LLVM bump --
    # a full Elixir rebuild to benefit the ~20 that compile C. The test is the package's own
    # sources, not its dependency closure: `uses_bundlex` is true for the entire Membrane
    # closure, but only a package shipping its own bundlex.exs actually declares natives.
    cc_exports = ""
    cc_inputs = []
    if _compiles_native_code(ctx):
        cc_toolchain = find_cc_toolchain(ctx)

        # cc_common directly rather than rules_foreign_cc's get_tools_info/get_flags_info:
        # those resolve `defines` by reading CcInfo off every entry in ctx.attr.deps, which
        # holds ErlangAppInfo mix_app targets here, so they fail analysis outright.
        feature_configuration = cc_common.configure_features(
            ctx = ctx,
            cc_toolchain = cc_toolchain,
            requested_features = ctx.features,
            unsupported_features = ctx.disabled_features,
        )
        compile_variables = cc_common.create_compile_variables(
            feature_configuration = feature_configuration,
            cc_toolchain = cc_toolchain,
        )
        link_variables = cc_common.create_link_variables(
            feature_configuration = feature_configuration,
            cc_toolchain = cc_toolchain,
        )

        def _tool(action):
            return cc_common.get_tool_for_action(
                feature_configuration = feature_configuration,
                action_name = action,
            )

        def _abs(text):
            return absolutize_path_in_str(ctx.workspace_name, "$ORIGINAL_DIR/", text)

        def _flags(action, variables):
            return " ".join([
                _abs(f)
                for f in cc_common.get_memory_inefficient_command_line(
                    feature_configuration = feature_configuration,
                    action_name = action,
                    variables = variables,
                )
            ])

        # Bundlex.Toolchain.Custom reads all five with System.fetch_env! and raises on a
        # missing one, so these are set together or not at all. elixir_make packages read
        # only CC/CFLAGS and ignore the rest.
        cc_env = {
            "CC": _abs(_tool(ACTION_NAMES.c_compile)),
            "CXX": _abs(_tool(ACTION_NAMES.cpp_compile)),
            "CFLAGS": _flags(ACTION_NAMES.c_compile, compile_variables),
            "CXXFLAGS": _flags(ACTION_NAMES.cpp_compile, compile_variables),
            "LDFLAGS": _flags(ACTION_NAMES.cpp_link_executable, link_variables),
        }

        # Double quotes, NOT shell.quote: $ORIGINAL_DIR has to be expanded HERE, by the
        # shell, so the variables carry literal absolute paths. Single-quoting them passes
        # the string "$ORIGINAL_DIR/..." through to make, which expands `$O` as an undefined
        # make variable and invokes `RIGINAL_DIR/.../clang`.
        cc_exports = "\n".join([
            'export {}="{}"'.format(k, v)
            for k, v in cc_env.items()
        ])
        cc_inputs = [cc_toolchain.all_files]

    # ONLY the dependencies that actually DECLARE natives, not the whole closure.
    #
    # This loop used to be `for dep in all_deps`, which staged the full source tree AND the
    # entire mix_tree -- staged sources plus _build -- of every package in the flattened
    # dependency graph, for any package that merely had bundlex somewhere beneath it.
    #
    # //elixir/serviceradar_core_elx is 41 modules and 8.5k LOC. The fitted cost of a mix
    # action in this repo is 4.7s + 0.19s/kLOC, i.e. ~6s. It took 74 SECONDS and was the
    # single largest action in the build, at the head of the critical path:
    #
    #   bundlex -> qex -> shmex -> unifex -> bunch_native -> membrane_common_c
    #     -> membrane_transcoder_plugin -> boombox -> membrane_ffmpeg_swscale_plugin
    #     -> serviceradar_core_elx (1m14s) -> OTP release (36s) -> rootfs (30s) -> OCI
    #
    # Nearly all of it was staging and uploading inputs it never opened. Repo-wide,
    # "Uploading missing inputs" was 10m32s of a 28m30s remote-execution total -- 24% --
    # and this path is the bulk of it, because each link in that chain re-stages its
    # predecessors' whole trees.
    #
    # The precise requirement is narrow: Bundlex.Project.load/1 does
    # Code.require_file("deps/<app>/bundlex.exs"), so the only dependencies whose sources are
    # ever read are the ones that ship a bundlex.exs. That is directly observable from the
    # dependency's own srcs, so it is detected rather than declared -- the same reasoning as
    # `uses_bundlex` above, and it keeps the 55 generated third_party/hex BUILD files free of
    # a hand-maintained list.
    #
    # Transitivity is preserved: unifex's bundlex.exs names shmex and shmex's names
    # bunch_native, but each of those ships its own bundlex.exs, so all three are selected.
    bundlex_deps = []
    if uses_bundlex:
        for dep in all_deps:
            for dep_file in dep[ErlangAppInfo].srcs:
                if dep_file.basename == "bundlex.exs":
                    bundlex_deps.append(dep)
                    break

    dep_source_commands = []
    dep_source_files = []
    if uses_bundlex:
        # Batched by destination directory for the same reason as the srcs staging above:
        # a mkdir+cp pair per file, each with a $(dirname) subshell, is thousands of process
        # spawns before anything compiles.
        dep_batched = {}
        dep_dirs = {}
        for dep in bundlex_deps:
            dep_info = dep[ErlangAppInfo]
            for dep_file in dep_info.srcs:
                if dep_file.is_directory:
                    continue
                dest = path_join(
                    "deps",
                    dep_info.app_name,
                    additional_file_dest_relative_path(dep.label, dep_file),
                )
                dest_dir = dest.rpartition("/")[0]
                dep_dirs[dest_dir] = True
                dep_source_files.append(dep_file)
                if dep_file.basename == dest.rpartition("/")[2]:
                    dep_batched.setdefault(dest_dir, []).append(dep_file.path)
                else:
                    dep_source_commands.append(
                        'cp "{src}" "${{MIX_INVOCATION_DIR}}/{dest}"'.format(
                            src = dep_file.path,
                            dest = dest,
                        ),
                    )

        ddirs = sorted([d for d in dep_dirs if d])
        for i in range(0, len(ddirs), 400):
            dep_source_commands.insert(i // 400, "mkdir -p {}".format(" ".join([
                '"${{MIX_INVOCATION_DIR}}/{}"'.format(d)
                for d in ddirs[i:i + 400]
            ])))
        for dest_dir in sorted(dep_batched):
            paths = dep_batched[dest_dir]
            for i in range(0, len(paths), 400):
                dep_source_commands.append('cp {srcs} "${{MIX_INVOCATION_DIR}}/{dir}/"'.format(
                    srcs = " ".join(['"{}"'.format(p) for p in paths[i:i + 400]]),
                    dir = dest_dir,
                ))

    if uses_bundlex:
        for dep in bundlex_deps:
            dep_info = dep[ErlangAppInfo]

            # Then overlay the dependency's POST-COMPILE tree, which is where Unifex left
            # its generated headers (c_src/**/_generated/). Pristine sources alone give a
            # dependent `fatal error: _generated/membrane.h: No such file or directory`.
            #
            # _build, deps, .mix and mix.lock are excluded: they are that action's own
            # scratch state, and `deps` in particular would nest this staging inside itself.
            mix_trees = getattr(dep[OutputGroupInfo], "mix_tree", None)
            if mix_trees:
                for mix_tree in mix_trees.to_list():
                    dep_source_files.append(mix_tree)
                    dep_source_commands.append(
                        'if [ -d "{src}/{pkg}" ]; then\n'.format(
                            src = mix_tree.path,
                            pkg = dep.label.package,
                        ) +
                        '  mkdir -p "${{MIX_INVOCATION_DIR}}/deps/{app}"\n'.format(app = dep_info.app_name) +
                        '  tar -cf - -C "{src}/{pkg}" --exclude=_build --exclude=deps --exclude=.mix --exclude=.hex --exclude=mix.lock . | tar -xf - -C "${{MIX_INVOCATION_DIR}}/deps/{app}"\n'.format(
                            src = mix_tree.path,
                            pkg = dep.label.package,
                            app = dep_info.app_name,
                        ) +
                        "fi",
                    )

    # Mix does NOT read a Hex dependency's mix.exs to discover its children. Hex registers
    # as Mix.RemoteConverger, and Mix.Dep.Converger asks it instead:
    #     {:unloaded, dep, remote.deps(dep, lock)}
    # `Hex.RemoteConverger.deps/2` reads the lock, whose entries carry the dependency list.
    # Hex package tarballs do not ship mix.lock, so without one every staged dependency has
    # zero children and Mix.Project.deps_paths/0 holds only direct dependencies. Bundlex
    # resolves native apps through exactly that map, so a transitively-declared one fails:
    # unifex's bundlex.exs names shmex, shmex's names bunch_native, and unifex's mix.exs
    # never mentions bunch_native -> :unknown_application.
    #
    # So the lock is generated from the Bazel graph, which already knows the full closure.
    # Children come from ErlangAppInfo.deps -- flattened rather than direct, which is
    # harmless here: every app named is present, and the requirement is ">= 0.0.0" so
    # convergence cannot fail on a version range.
    lock_commands = ""
    if uses_bundlex:
        graph_entries = []
        for dep in all_deps:
            dep_info = dep[ErlangAppInfo]
            children = [child[ErlangAppInfo].app_name for child in dep_info.deps]
            graph_entries.append("{}: [{}]".format(
                dep_info.app_name,
                ", ".join([":" + child for child in children]),
            ))
        lock_commands = _MIX_LOCK_SCRIPT.replace(
            "__GRAPH__",
            "%{" + ", ".join(graph_entries) + "}",
        )

    # Bundlex fetches precompiled native libraries (ffmpeg, opus, srt, ...) with Req.get!
    # during compilation. Left alone that is a network fetch inside a build action: not
    # covered by the action key, dependent on executor egress, and repeated per consuming
    # plugin -- five separate 70.8 MB copies of libavcodec.so in one release.
    #
    # The archives are pinned http_file repos in //MODULE.bazel. Staging them here and
    # pointing BUNDLEX_LOCAL_PRECOMPILED_DIR at the directory makes the patched Bundlex in
    # //third_party/patches/bundlex copy instead of download. Matching is by URL basename.
    precompiled_commands = []
    if uses_bundlex and ctx.files.precompiled_os_deps:
        precompiled_commands.append('mkdir -p "${MIX_INVOCATION_DIR}/.bundlex_precompiled"')
        for f in ctx.files.precompiled_os_deps:
            precompiled_commands.append(
                'cp "{src}" "${{MIX_INVOCATION_DIR}}/.bundlex_precompiled/{name}"'.format(
                    src = f.path,
                    name = f.basename,
                ),
            )

    if ctx.files.precompiled_nifs:
        precompiled_commands.append('mkdir -p "${MIX_INVOCATION_DIR}/.precompiled_nifs"')
        for f in ctx.files.precompiled_nifs:
            precompiled_commands.append(
                'cp "{src}" "${{MIX_INVOCATION_DIR}}/.precompiled_nifs/{name}"'.format(
                    src = f.path,
                    name = f.basename,
                ),
            )

    # Staged into the copied source tree so `mix compile` picks them up as part of priv,
    # and mix_app's priv output carries them downstream.
    native_lib_commands = []
    native_lib_files = []
    for target, crate in ctx.attr.native_libs.items():
        files = target[DefaultInfo].files.to_list()
        if len(files) != 1:
            fail("native_libs entry {} must produce exactly one file, got {}".format(
                target.label,
                files,
            ))
        native_lib_files.append(files[0])
        native_lib_commands.append(
            'cp "{src}" priv/native/{crate}.so'.format(src = files[0].path, crate = crate),
        )
    if native_lib_commands:
        native_lib_commands = ["mkdir -p priv/native"] + native_lib_commands

    # Appended last so these win over anything config.exs imports for the env.
    #
    # `config/2` has to be in scope for the appended lines, and creating the file when absent
    # is not enough to guarantee that across third-party packages:
    #
    #   * yaml_elixir ships a config/config.exs that is a single newline. It satisfies the -f
    #     test, so nothing imports Config, and the appended lines fail with
    #     "undefined function config/2".
    #   * stream_split ships one using the deprecated `use Mix.Config`. An unconditional
    #     `import Config` there fails the other way: "function config/2 imported from both
    #     Config and Mix.Config, call is ambiguous".
    #
    # So import only when the file provides neither form.
    #
    # A file whose last line has no trailing newline would also splice the first appended
    # line onto it ("# commentimport Config"), so terminate it before appending anything.
    extra_config_commands = ""
    if ctx.attr.extra_config:
        extra_config_commands = "\n".join([
            "mkdir -p config",
            "[ -f config/config.exs ] || echo 'import Config' > config/config.exs",
            "if [ -s config/config.exs ] && [ -n \"$(tail -c1 config/config.exs)\" ]; then " +
            "echo >> config/config.exs; fi",
            "grep -qE '^[[:space:]]*(import Config|use Mix\\.Config)' config/config.exs || " +
            "echo 'import Config' >> config/config.exs",
            "cat >> config/config.exs <<'__BAZEL_EXTRA_CONFIG__'",
        ] + ctx.attr.extra_config + [
            "__BAZEL_EXTRA_CONFIG__",
        ])

    script = """set -euo pipefail

{maybe_install_erlang}

if [ -n "{erl_libs_path}" ]; then
    export ERL_LIBS="{erl_libs_path}"
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
rm -rf "${{MIX_INVOCATION_DIR}}"
mkdir -p "${{MIX_INVOCATION_DIR}}"
{mix_dir_cleanup}

{copy_srcs_commands}

ORIGINAL_DIR=$PWD
cd "${{MIX_INVOCATION_DIR}}/{project_dir}"

# HOME must live inside the sandbox: Mix writes ~/.mix and ~/.hex, and a stray
# write to the real home directory is exactly the non-hermeticity we are here
# to avoid.
export HOME="${{PWD}}"
export MIX_ENV={mix_env}
export ERL_COMPILER_OPTIONS=deterministic

# Stops MIX resolving dependencies over the network. It does NOT stop a package's own
# compile-time :httpc call -- cc_precompiler, rustler_precompiled and Adbc.download_driver!
# all went straight past it, each fetching an artefact keyed on the executor's CPU.
#
# There is no sandbox fix for that here: the RBE executor must reach the BuildBuddy cache
# proxy, so the action cannot be network-isolated. `block-network` was tried and is not
# honoured by this executor -- verified by sabotaging the artefact cache and watching the
# download succeed anyway. The enforceable invariant is therefore about the OUTPUT, not the
# network: see the ELF check at the end of this script.
export HEX_OFFLINE=1

# What architecture this build is FOR, for packages that fetch a prebuilt artefact
# instead of compiling one. See _target_triple_env.
{target_triple_exports}

# Points the patched Bundlex at the Bazel-staged archives. Harmless when the directory is
# absent: Bundlex falls back to its original download path.
export BUNDLEX_LOCAL_PRECOMPILED_DIR="$PWD/.bundlex_precompiled"

# rustler_precompiled reads this path VERBATIM (it does not append a subdirectory) and
# looks for <path>/<exact archive name>, verifying it against the package's checksum file
# before extracting. Present -> no network. Absent -> it would download, which is what
# block-network now forbids.
export RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH="$PWD/.precompiled_nifs"

# The hermetic C toolchain, for the packages that compile native code. Paths arrive
# execroot-relative and we have already cd'd into the mix invocation dir, so they are
# absolutized against $ORIGINAL_DIR rather than $PWD.
{cc_exports}

for archive in {archives}; do
    "${{ABS_ELIXIR_HOME}}"/bin/mix archive.install --force $ORIGINAL_DIR/$archive
done

if [[ -n "{erl_libs_path}" ]]; then
    mkdir -p _build/${{MIX_ENV}}/lib
    # ERL_LIBS is a colon-separated LIST of directories, not one directory: most
    # dependencies are referenced where they were built rather than copied into a merged
    # tree. -n keeps an existing link, so a staged copy of an app wins over a direct one.
    for erl_libs_entry in $(printf '%s' "$ERL_LIBS" | tr ':' ' '); do
        for dep in "$erl_libs_entry"/*; do
            [ -e "$dep" ] || continue
            dep_name=$(basename "$dep")
            # First entry wins, matching ERL_LIBS resolution order.
            if [ ! -e "_build/${{MIX_ENV}}/lib/$dep_name" ]; then
                ln -s "$dep" "_build/${{MIX_ENV}}/lib/$dep_name"
            fi
        done
    done
fi

{lock_commands}

{extra_config_commands}

{native_lib_commands}

{setup}

# SIZE THE BEAM TO THE CGROUP, NOT TO THE HOST.
#
# DEFENSIVE, NOT A MEASURED WIN -- do not credit a speedup to it. On the current executors
# the two already agree, measured inside the action:
#
#   host_nproc=64  cgroup_cpu_max="3000000 100000"  ->  30 CPU quota
#   schedulers_online=30
#
# (cpu.max is "quota period" in microseconds: 3000000/100000 = 30 CPUs, not 3. Misreading
# that is easy and sends you looking for a CPU-starvation problem that is not there.)
#
# The reason to pin it anyway is that the agreement is a coincidence of this executor's
# sizing. The BEAM calls sysconf(_SC_NPROCESSORS_ONLN), which reports HOST cores and ignores
# the cgroup quota entirely; it lands on 30 here because the quota happens to be 30 of the
# node's 64. Change the executor's CPU limits or give a mix target its own exec_properties
# and the two diverge silently, leaving schedulers oversubscribed against a smaller quota
# with no error -- only a slower compile.
#
# Derived at runtime rather than hardcoded so it cannot drift out of sync with whatever
# quota the action is actually granted. cgroup v2 first, then v1, then nproc for a machine
# with no cgroup at all (a developer's workstation).
# Deliberately no awk here: this whole script is a Starlark .format() template, so an awk
# program's braces would be read as format placeholders and fail at ANALYSIS time, across
# every mix_app target in the repo at once. Shell arithmetic needs no braces.
_SR_CPUS=""
_SR_QUOTA=""
_SR_PERIOD=""
if [ -r /sys/fs/cgroup/cpu.max ]; then
    read -r _SR_QUOTA _SR_PERIOD < /sys/fs/cgroup/cpu.max || true
elif [ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us ] && [ -r /sys/fs/cgroup/cpu/cpu.cfs_period_us ]; then
    read -r _SR_QUOTA < /sys/fs/cgroup/cpu/cpu.cfs_quota_us || true
    read -r _SR_PERIOD < /sys/fs/cgroup/cpu/cpu.cfs_period_us || true
fi
# "max" means unlimited; a negative quota is cgroup v1's way of saying the same.
case "$_SR_QUOTA" in
    ''|max|-*) ;;
    *[!0-9]*) ;;
    *)
        if [ "${{_SR_PERIOD:-0}}" -gt 0 ] 2>/dev/null; then
            _SR_CPUS=$(( (_SR_QUOTA + _SR_PERIOD - 1) / _SR_PERIOD ))
        fi
        ;;
esac
if [ -z "$_SR_CPUS" ] || [ "$_SR_CPUS" -lt 1 ] 2>/dev/null; then
    _SR_CPUS=$(nproc 2>/dev/null || echo 1)
fi

# +S <total>:<online> pins the scheduler pool to the quota.
# +fnu fixes a real defect, not a cosmetic one: the executor image has no UTF-8 locale, so
# setlocale fails and the VM falls back to latin1 filename encoding, which Elixir itself warns
# "may cause Elixir to malfunction". Forcing utf8 filename handling makes it independent of
# the image's locale configuration.
export ELIXIR_ERL_OPTIONS="+S ${{_SR_CPUS}}:${{_SR_CPUS}} +fnu ${{ELIXIR_ERL_OPTIONS:-}}"

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

{elf_arch_assertion}

""".format(
        maybe_install_erlang = maybe_install_erlang(ctx),
        erl_libs_path = erl_libs_path,
        erlang_home = erlang_home,
        elixir_home = elixir_home,
        # A DETERMINISTIC scratch directory, not `$(mktemp -d)`.
        #
        # Mix records paths of the tree it compiles, and those end up inside the .beam
        # files, so a random /tmp/tmp.XXXXXXXX made every build of an unchanged package
        # produce different bytes -- two builds of one target differed ONLY by that path.
        # Named per target (the label alone is "erlang_app" for all 268 hex packages, so
        # the app name is what actually disambiguates) and relative to the execroot, which
        # each action already has to itself.
        mix_invocation_dir = mix_invocation_dir.path if ships_bundlex else ".mix_{}_{}".format(ctx.label.name, app_name),
        mix_dir_cleanup = "" if ships_bundlex else 'trap \'rm -rf "${MIX_INVOCATION_DIR}"\' EXIT',
        project_dir = ctx.label.package,
        copy_srcs_commands = "\n".join(copy_srcs_commands + dep_source_commands + precompiled_commands),
        archives = " ".join([shell.quote(a.path) for a in ctx.files.archives]),
        target_triple_exports = "\n".join([
            "export {}={}".format(k, v)
            for k, v in sorted(_target_triple_env(ctx).items())
        ]),
        elf_arch_assertion = _elf_arch_assertion(ctx),
        mix_env = ctx.attr.mix_env,
        lock_commands = lock_commands,
        extra_config_commands = extra_config_commands,
        native_lib_commands = "\n".join([
            c.replace('cp "', 'cp "$ORIGINAL_DIR/') if c.startswith("cp ") else c
            for c in native_lib_commands
        ]),
        setup = ctx.attr.setup,
        app_name = app_name,
        ebin = ebin.path,
        priv = priv.path,
        cc_exports = cc_exports,
    )

    inputs = depset(
        direct = ctx.files.srcs,
        transitive = [
            erlang_runfiles.files,
            elixir_runfiles.files,
            depset(ctx.files.archives),
            depset(dep_source_files),
            depset(ctx.files.precompiled_os_deps),
            depset(ctx.files.precompiled_nifs),
            depset(native_lib_files),
            depset(erl_libs_files),
            # Referenced in place via ERL_LIBS rather than staged, so they have to be
            # declared here or the action would not see them.
            depset(direct_dep_files),
        ] + cc_inputs,
    )

    ctx.actions.run_shell(
        inputs = inputs,
        outputs = [ebin, priv] + ([mix_invocation_dir] if ships_bundlex else []),
        command = script,
        mnemonic = "MIX",
        progress_message = "Compiling Mix package %s" % app_name,
    )

    deps = all_deps

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
        # The whole post-compile tree, for the one consumer that needs more than ebin+priv.
        #
        # Unifex generates C headers into a package's own c_src/**/_generated/ while that
        # package compiles. A dependent then does #include "_generated/membrane.h" against
        # the DEPENDENCY's tree, so staging pristine sources is not enough:
        #     deps/membrane_common_c/c_src/membrane/log.h:6:10:
        #         fatal error: _generated/membrane.h: No such file or directory
        # The generated headers only exist inside the producing action, and ErlangAppInfo
        # carries neither them nor a place to put them -- but the Mix invocation directory
        # is already a declared output, so it is simply surfaced here.
        OutputGroupInfo(mix_tree = depset([mix_invocation_dir] if ships_bundlex else [])),
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
        # Bazel-built NIF shared libraries to stage into priv/native before compiling,
        # keyed by target with the Rustler crate name as the value. rustler resolves a NIF
        # as Application.app_dir(otp_app, "priv/native/<crate>") and :erlang.load_nif
        # appends the platform extension -- which is ".so" on macOS too, not ".dylib". So
        # the cdylib is installed as priv/native/<crate>.so, dropping cargo's "lib" prefix.
        #
        # cfg: NIFs build in `opt` regardless of the invocation's mode. See
        # _nif_opt_transition above.
        "native_libs": attr.label_keyed_string_dict(
            allow_files = True,
            cfg = _nif_opt_transition,
        ),
        # Config lines appended to config/config.exs *inside the action*, i.e. to the
        # sandbox copy -- the checked-in file is never touched. This exists so a
        # build-system concern can be expressed in the build system instead of in
        # production config. The motivating case is Rustler: `use Rustler` reads
        # Application.compile_env(otp_app, __MODULE__) and merges it OVER the use-options
        # (rustler/lib/rustler/compiler/config.ex), so `skip_compilation?: true` set here
        # keeps cargo out of the Bazel action without changing what `mix release` does.
        "extra_config": attr.string_list(),
        # Archives Bundlex would otherwise download mid-build. Only staged when the
        # package actually depends on bundlex, so this costs nothing for the other 271.
        "precompiled_os_deps": attr.label_list(
            allow_files = True,
            default = ["//third_party/membrane:precompiled_os_deps"],
        ),
        # Precompiled Rustler NIF archives, so rustler_precompiled finds its artefact in a
        # declared input instead of fetching it. Staged for every package; the ones that
        # use no precompiled NIF never look. See //third_party/precompiled_nifs.
        "precompiled_nifs": attr.label_list(
            allow_files = True,
            default = ["//third_party/precompiled_nifs:precompiled_nifs"],
        ),
        "mix_env": attr.string(default = "prod"),
        "deps": attr.label_list(providers = [ErlangAppInfo]),
        # Read only to answer "what CPU is this build FOR". See _target_triple_env.
        "_cpu_aarch64": attr.label(default = "@platforms//cpu:aarch64"),
        "_os_linux": attr.label(default = "@platforms//os:linux"),
    },
    provides = [ErlangAppInfo],
    toolchains = ["@rules_elixir//:toolchain_type"] + use_cc_toolchain(),
    fragments = ["cpp"],
)
