"""Assemble an OTP release from Bazel-built applications. No compilation.

Why this exists
---------------
`//build:mix_release.bzl` is not a Bazel rule in any meaningful sense: it has no
`deps`, so it cannot consume a provider. Every dependency edge therefore has to be
re-expressed as raw file copying, and the attribute list is the receipt --
`extra_dirs`, `extra_dir_srcs`, `native_libs`, `extra_config`, `precompiled_os_deps`,
`hex_cache`, `bootstrap_srcs`, `workdir_name`, `bun`, `sfw` all exist to hand-simulate
what `deps` gives for free. It reconstructs a fake workspace in the sandbox, runs
`mix deps.get` over the network, and recompiles ~170 Hex packages that Bazel has
*already built* as individually cached targets. One 578s action, unparallelizable,
against a mutable `/cache` directory outside the action key.

This rule is the missing `rust_binary` to `mix_app`'s `rust_library`. Its input is a
provider -- the transitive `ErlangAppInfo` closure of one application -- and its job is
assembly only: stage every app's already-compiled `ebin`/`priv` into `_build/$MIX_ENV/lib`
and let `mix release` lay out the boot script, `sys.config`, `vm.args` and ERTS.

`mix release` is kept as the assembler on purpose. The alternative -- driving `systools`
directly -- means reimplementing `Mix.Release`: config providers, `rel/env.sh.eex`,
overlays, and the `bin/<name>` launcher that every runbook in this repo calls
(`/app/bin/serviceradar_web_ng remote`). Assembly is not the expensive part; compilation
is, and compilation is what moves out.

What the release action no longer does: fetch anything, compile anything, run cargo,
run a JS package manager, or read/write a directory outside its own sandbox.

NIFs need no special handling here. A `.so` reaches the release as part of its owning
app's `priv`, because `mix_app` already staged it there when it compiled that app --
which is why this rule has no `native_libs` and needs no `skip_compilation?` config
patching: Rustler is never invoked.
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

    tar_out = ctx.outputs.out

    # The whole point of the rule: the applications to ship are read off a provider,
    # transitively, instead of being listed by hand as source directories. `flat_deps`
    # includes the roots, so the release's own app arrives here too.
    apps = flat_deps([ctx.attr.app])

    erl_libs_dir = ctx.label.name + "_apps"
    erl_libs_files = erl_libs_contents(
        ctx,
        target_info = None,
        headers = False,
        dir = erl_libs_dir,
        deps = apps,
        ez_deps = [],
        expand_ezs = False,
    )
    erl_libs_path = path_join(
        ctx.bin_dir.path,
        ctx.label.workspace_root,
        ctx.label.package,
        erl_libs_dir,
    )

    # Generated content that belongs to the application but is not produced by compiling
    # it -- digested CSS/JS for a Phoenix app being the whole motivating case. Unpacked
    # into the staged app directory BEFORE `mix release`, which is the point at which Mix
    # reads priv/, so the assembler needs no special knowledge of assets.
    #
    # This is what keeps `bun install`, tailwind and esbuild out of the release action:
    # they become their own cacheable target keyed on assets/**, instead of re-running
    # every time an .ex file changes.
    # Appended to the SANDBOX copy of config/config.exs, never the checked-in file.
    #
    # This is not the same thing as mix_release's `extra_config`, which existed to defeat
    # Rustler at compile time. Nothing is compiled here. It exists because `mix release`
    # verifies that every Application.compile_env/2 key holds the same value now as it did
    # when the app was compiled, and fails with "has a different value set for key ... during
    # runtime compared to compile time" otherwise. The apps were compiled by mix_app with
    # its own extra_config applied, so the release has to be told the same thing. Pass the
    # SAME list to both; a BUILD-file variable shared between them is the way to keep them
    # from drifting.
    extra_config_cmds = ""
    if ctx.attr.extra_config:
        extra_config_cmds = "\n".join([
            "mkdir -p config",
            "[ -f config/config.exs ] || echo 'import Config' > config/config.exs",
            "cat >> config/config.exs <<'__BAZEL_EXTRA_CONFIG__'",
        ] + ctx.attr.extra_config + [
            "__BAZEL_EXTRA_CONFIG__",
        ])

    release_app_name = ctx.attr.app[ErlangAppInfo].app_name
    overlay_files = []
    overlay_cmds = []
    for target, dest in ctx.attr.overlays.items():
        files = target[DefaultInfo].files.to_list()
        if len(files) != 1:
            fail("overlays entry {} must produce exactly one tar, got {}".format(
                target.label,
                files,
            ))
        overlay_files.append(files[0])
        overlay_cmds.append(
            'OVERLAY_DEST="_build/$MIX_ENV/lib/{app}/{dest}"\n'.format(
                app = release_app_name,
                dest = dest,
            ) +
            'mkdir -p "$OVERLAY_DEST"\n' +
            'tar -xzf "$EXECROOT/{src}" -C "$OVERLAY_DEST"\n'.format(src = files[0].path),
        )

    # Only the release RECIPE is staged as source: mix.exs (for `releases/0`), config/,
    # and rel/ templates. Not lib/ -- that is already compiled and arrives via `app`.
    # Layout mirrors the workspace because mix.exs names path deps relatively
    # ({:serviceradar_core, path: "../serviceradar_core"}) and Mix reads each one's
    # mix.exs to learn its app name and version.
    copy_srcs_commands = []
    for src in ctx.attr.srcs:
        for src_file in src[DefaultInfo].files.to_list():
            dest = path_join(
                src.label.package,
                additional_file_dest_relative_path(src.label, src_file),
            )
            copy_srcs_commands.extend([
                'mkdir -p "$(dirname "$WORKDIR/{dest}")"'.format(dest = dest),
                'cp {flags}"$EXECROOT/{src}" "$WORKDIR/{dest}"'.format(
                    flags = "-r " if src_file.is_directory else "",
                    src = src_file.path,
                    dest = dest,
                ),
            ])

    script = """set -euo pipefail

{maybe_install_erlang}

EXECROOT=$PWD

if [[ "{elixir_home}" == /* ]]; then
    ABS_ELIXIR_HOME="{elixir_home}"
else
    ABS_ELIXIR_HOME=$PWD/{elixir_home}
fi
export PATH="$ABS_ELIXIR_HOME"/bin:"{erlang_home}"/bin:${{PATH}}

export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"

# The staged application tree. Both Mix and the ERTS resolve applications through the
# code path, so exporting ERL_LIBS is what makes `Application.load/1` find an app that is
# reached transitively rather than named in this project's mix.exs -- :phoenix_pubsub
# arrives via ash_admin -> phoenix, and is named only in `extra_applications`.
export ERL_LIBS="$PWD/{erl_libs_path}"

WORKDIR=$(mktemp -d)
{copy_srcs_commands}

cd "$WORKDIR/{project_dir}"

# HOME inside the sandbox. Mix writes ~/.mix and ~/.hex; letting that reach the real
# home directory is the non-hermeticity this rule exists to remove.
export HOME="$PWD/.home"
mkdir -p "$HOME"
export MIX_ENV={mix_env}

# Every application is already a declared input. If Mix reaches for the network, fail
# here rather than succeed locally and fail on a network-isolated RBE executor.
export HEX_OFFLINE=1
export ERL_COMPILER_OPTIONS=deterministic

# Mix refuses to start when it cannot resolve an SCM for a dependency named in mix.exs --
# even one it will never fetch, because HEX_OFFLINE only stops the network, it does not
# remove the requirement that the Hex SCM be *registered*. Installed from a declared
# input, never downloaded.
for archive in {archives}; do
    "${{ABS_ELIXIR_HOME}}"/bin/mix archive.install --force "$EXECROOT/$archive"
done

# The assembled tree Mix reads from. Copy rather than symlink: `mix release` walks
# _build to collect each application, and a link pointing back into the read-only
# ERL_LIBS staging tree makes that traversal depend on where Bazel happened to put it.
mkdir -p _build/$MIX_ENV/lib
STAGED=0
for app in "$ERL_LIBS"/*; do
    [ -d "$app" ] || continue
    cp -RL "$app" _build/$MIX_ENV/lib/
    STAGED=$((STAGED + 1))
done
if [ "$STAGED" -eq 0 ]; then
    echo "no applications staged from ERL_LIBS=$ERL_LIBS -- the release would be empty" >&2
    exit 1
fi
chmod -R u+w _build

{extra_config}

{overlays}

# --no-compile is what makes this assembly rather than a build: every .beam already
# exists. --no-deps-check because deps/ is deliberately absent -- the dependency graph
# lives in Bazel, not in a fetched deps directory.
RELEASE_DIR=$(mktemp -d)
mix release {release_name}--no-compile --no-deps-check --overwrite --path "$RELEASE_DIR"

# Mix can leave links pointing back into _build. Materialize before archiving so the
# tarball is self-contained inside the image.
PACKAGED=$(mktemp -d)
cp -RL "$RELEASE_DIR"/. "$PACKAGED"/

mkdir -p "$(dirname "$EXECROOT/{tar_out}")"
tar -czf "$EXECROOT/{tar_out}" -C "$PACKAGED" .
""".format(
        maybe_install_erlang = maybe_install_erlang(ctx),
        erlang_home = erlang_home,
        elixir_home = elixir_home,
        erl_libs_path = erl_libs_path,
        copy_srcs_commands = "\n".join(copy_srcs_commands),
        archives = " ".join([shell.quote(a.path) for a in ctx.files.archives]),
        extra_config = extra_config_cmds,
        overlays = "\n".join(overlay_cmds),
        project_dir = ctx.label.package,
        mix_env = ctx.attr.mix_env,
        # Named only when mix.exs declares `releases:`. web-ng does not, and passing a name
        # that has no entry there fails with "Unknown release ... available releases are: []".
        # With no name, `mix release` assembles the implicit release named after the app,
        # which is exactly what mix_release did.
        release_name = ctx.attr.release_name + " " if ctx.attr.release_name else "",
        tar_out = tar_out.path,
    )

    inputs = depset(
        direct = ctx.files.srcs + ctx.files.archives + erl_libs_files + overlay_files,
        transitive = [
            erlang_runfiles.files,
            elixir_runfiles.files,
        ],
    )

    ctx.actions.run_shell(
        inputs = inputs,
        outputs = [tar_out],
        command = script,
        mnemonic = "ElixirRelease",
        progress_message = "Assembling OTP release %s" % release_app_name,
    )

    return [DefaultInfo(files = depset([tar_out]))]

elixir_release = rule(
    implementation = _impl,
    attrs = {
        # The release's own application, prod-compiled. Its transitive ErlangAppInfo
        # closure IS the release contents -- there is no second list to keep in sync.
        "app": attr.label(mandatory = True, providers = [ErlangAppInfo]),
        "release_name": attr.string(doc = "Release name from mix.exs releases/0. Empty when mix.exs declares none."),
        # The release recipe only: mix.exs, config/**, rel/**, plus each path dep's
        # mix.exs. Never lib/ -- compiled code arrives through `app`.
        "srcs": attr.label_list(allow_files = True),
        "archives": attr.label_list(
            allow_files = [".ez"],
            default = ["@hex//:archive"],
        ),
        # Tarballs of generated, non-compiled content, keyed by target with the
        # destination relative to the release application's own directory. A Phoenix app
        # passes {"//elixir/web-ng/assets:static": "priv"} so the digested asset tree
        # lands at priv/static without the release action ever running a JS toolchain.
        "overlays": attr.label_keyed_string_dict(allow_files = True),
        # Must match the extra_config the applications were COMPILED with. See the comment
        # at the emission site: `mix release` refuses to assemble when a compile_env key
        # differs between compile time and release time.
        "extra_config": attr.string_list(),
        "mix_env": attr.string(default = "prod"),
        "out": attr.output(mandatory = True),
    },
    toolchains = [
        "@rules_elixir//:toolchain_type",
    ],
)
