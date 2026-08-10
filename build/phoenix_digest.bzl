"""Digest a Phoenix static tree (`mix phx.digest`) as a standalone Bazel action.

Why this is not just part of the release
----------------------------------------
config/prod.exs sets `cache_static_manifest: "priv/static/cache_manifest.json"`, so a
production release needs the DIGESTED tree: every asset copied to a content-hashed name,
gzipped siblings, and a manifest mapping logical paths to hashed ones. Without it
`~p"/assets/app.css"` renders undigested and cache busting silently stops working.

//build:mix_release.bzl did this inside the release action, which is why an .ex-only
change re-ran the whole asset pipeline. Here it is keyed on the static tree alone.

`Phoenix.Digester.compile/3` is called directly rather than through `mix phx.digest`.
The Mix task exists to locate the project's priv/static and read its config; both are
inputs here, and requiring a Mix project would drag mix.exs and the dependency graph into
an action whose only job is hashing files.
"""

load(
    "@rules_elixir//private:elixir_toolchain.bzl",
    "elixir_dirs",
    "erlang_dirs",
    "maybe_install_erlang",
)
load("@rules_erlang//:erlang_app_info.bzl", "ErlangAppInfo", "flat_deps")
load("@rules_erlang//:util.bzl", "path_join")
load("@rules_erlang//private:util.bzl", "erl_libs_contents")

def _impl(ctx):
    (erlang_home, _, erlang_runfiles) = erlang_dirs(ctx)
    (elixir_home, elixir_runfiles) = elixir_dirs(ctx)

    tar_out = ctx.outputs.out
    src_dir = ctx.file.src

    erl_libs_dir = ctx.label.name + "_apps"
    erl_libs_files = erl_libs_contents(
        ctx,
        target_info = None,
        headers = False,
        dir = erl_libs_dir,
        deps = flat_deps(ctx.attr.deps),
        ez_deps = [],
        expand_ezs = False,
    )
    erl_libs_path = path_join(
        ctx.bin_dir.path,
        ctx.label.workspace_root,
        ctx.label.package,
        erl_libs_dir,
    )

    script = """set -euo pipefail

{maybe_install_erlang}

EXECROOT=$PWD
export ERL_LIBS="$PWD/{erl_libs_path}"

if [[ "{elixir_home}" == /* ]]; then
    ABS_ELIXIR_HOME="{elixir_home}"
else
    ABS_ELIXIR_HOME=$PWD/{elixir_home}
fi
export PATH="$ABS_ELIXIR_HOME"/bin:"{erlang_home}"/bin:${{PATH}}
export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"

WORK=$(mktemp -d)
export HOME="$WORK/.home"
mkdir -p "$HOME"

# Digester rewrites in place alongside the originals, so work on a copy: the input is a
# read-only Bazel output tree.
IN="$WORK/in"
mkdir -p "$IN"
cp -RL "$EXECROOT/{src}"/. "$IN"/
chmod -R u+w "$IN"

# Application.load/1 first: the digester reads :phoenix's application environment for
# :static_compressors, and without the .app loaded that is an ArgumentError rather than the
# documented default. Loading (not starting) is enough -- nothing here needs a supervision
# tree.
#
# with_vsn? = false. The version suffix is for the legacy `?vsn=d` query-string scheme;
# Phoenix's manifest-based lookup does not use it and it only bloats the tree.
elixir -e '
  Application.load(:phoenix)
  [input, output] = System.argv()
  Phoenix.Digester.compile(input, output, false)
' "$IN" "$IN"

mkdir -p "$(dirname "$EXECROOT/{tar_out}")"
tar -czf "$EXECROOT/{tar_out}" --transform 's,^\\./,{prefix}/,' -C "$IN" .
""".format(
        maybe_install_erlang = maybe_install_erlang(ctx),
        erlang_home = erlang_home,
        elixir_home = elixir_home,
        erl_libs_path = erl_libs_path,
        src = src_dir.path,
        tar_out = tar_out.path,
        prefix = ctx.attr.prefix,
    )

    ctx.actions.run_shell(
        inputs = depset(
            direct = [src_dir] + erl_libs_files,
            transitive = [erlang_runfiles.files, elixir_runfiles.files],
        ),
        outputs = [tar_out],
        command = script,
        mnemonic = "PhoenixDigest",
        progress_message = "Digesting static assets for %s" % ctx.label,
    )

    return [DefaultInfo(files = depset([tar_out]))]

phoenix_digest = rule(
    implementation = _impl,
    attrs = {
        "src": attr.label(mandatory = True, allow_single_file = True, doc = "Undigested static tree"),
        # Only phoenix is needed -- Phoenix.Digester has no other runtime dependency.
        "deps": attr.label_list(
            providers = [ErlangAppInfo],
            default = ["@hexpm//:phoenix"],
        ),
        "prefix": attr.string(
            default = "static",
            doc = "Path the tree is placed at inside the tar, relative to the overlay destination",
        ),
        "out": attr.output(mandatory = True),
    },
    toolchains = ["@rules_elixir//:toolchain_type"],
)
