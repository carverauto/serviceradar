load("//:erlang_app_info.bzl", "ErlangAppInfo")
load("//:util.bzl", "path_join")
load(":util.bzl", "erl_libs_contents")
load(
    "//tools:erlang_toolchain.bzl",
    "erlang_dirs",
    "maybe_install_erlang",
)

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
    package_dir = path_join(
        ctx.label.workspace_root,
        ctx.label.package,
    )

    include_dirs = unique_dirnames(ctx.files.beams)

    srcs = ctx.actions.args()
    srcs.add_all([ctx.files.src])

    (erlang_home, _, runfiles) = erlang_dirs(ctx)

    outputs = ctx.outputs.outs

    script = """set -euo pipefail

TMP=$(mktemp -d || mktemp -d -t bazel-tmp)
test -d "$TMP"
trap "rm -fr '$TMP'" EXIT

{maybe_install_erlang}

mkdir -p {out_dirs}

SRC_DICT="$1"
INCLUDE_OPTS='{include_opts}'
CODEC_OPTS='{codec_opts}'

"{erlang_home}"/bin/erl \\
    -noshell \\
    -eval "ok = diameter_make:codec(\\"$SRC_DICT\\", [$CODEC_OPTS]++[$INCLUDE_OPTS]++[{{outdir,\\"$TMP\\"}}])" \\
    -s erlang halt

for F in {out_files} ; do
    SRC="$TMP/${{F##*/}}"
    mv -v "$SRC" "$F"
done
    """.format(
        maybe_install_erlang = maybe_install_erlang(ctx),
        erlang_home = erlang_home,
        out_dirs = " ".join(unique_dirnames(outputs)),
        out_files = " ".join([f.path for f in outputs]),
        erl_libs_path = "",
        codec_opts = ",".join(ctx.attr.codec_opts),
        include_opts = ",".join(["{include,\"%s\"}" % d for d in include_dirs]),
    )

    src = [S.path for S in ctx.files.src]

    inputs = depset(
        direct = ctx.files.src + ctx.files.beams,
        transitive = [runfiles.files],
    )

    ctx.actions.run_shell(
        inputs = inputs,
        outputs = outputs,
        command = script,
        arguments = src,
        mnemonic = "ERLDIA",
    )

    return [
        DefaultInfo(files = depset(outputs)),
    ]

erlang_dia = rule(
    implementation = _impl,
    attrs = {
        "app_name": attr.string(),
        "src": attr.label(
            mandatory = True,
            doc = "The dia file to compile",
            allow_single_file = [".dia"],
        ),
        "beams": attr.label_list(
            doc = "The beam files for the inherited dictionaries",
            allow_files = [".beam"],
        ),
        "deps": attr.label_list(
            providers = [ErlangAppInfo],
        ),
        "codec_opts": attr.string_list(
            doc = "Transformation options for diameter_make:codec (only use 'name', 'prefix' or 'inherits' otions)",
        ),
        "outs": attr.output_list(
            doc = "The erl and hrl file to be created (same basename like the src)",
            mandatory = True,
        ),
    },
    toolchains = ["//tools:toolchain_type"],
)
