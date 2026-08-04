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

    include_args = []
    if package_dir != "":
        include_args.extend(["-I", package_dir])
    for dir in unique_dirnames(ctx.files.incs):
        include_args.extend(["-I", dir])

    srcs = ctx.actions.args()
    srcs.add_all(ctx.files.srcs)

    (erlang_home, _, runfiles) = erlang_dirs(ctx)

    outputs = ctx.outputs.outs

    script = """set -euo pipefail

TMP=$(mktemp -d || mktemp -d -t bazel-tmp)
test -d "$TMP"
trap "rm -fr '$TMP'" EXIT

{maybe_install_erlang}

mkdir -p {out_dirs}

"{erlang_home}"/bin/erlc \\
    +noobj \\
    -v {include_args} \\
    -o "$TMP" \\
    $@

wrap_ext() {{
    IS_EXT=0
    while IFS="" read L ; do
        case "$IS_EXT:$L" in
            "0:-record('EXTERNAL',"*)
                printf "%s\\n" \\
                    "-ifndef(_EXTERNAL_HRL_)." \\
                    "-define(_EXTERNAL_HRL_, true)." \\
                    "$L"
                IS_EXT=1
                ;;
            1:*")."*)
                printf "%s\\n" \\
                    "$L" \\
                    "-endif."
                IS_EXT=0
                ;;
            *)
                printf "%s\\n" "$L"
                ;;
        esac
    done
}}

for F in {out_files} ; do
    SRC="$TMP/${{F##*/}}"
    case "$SRC" in
        *.hrl)
            wrap_ext < "$SRC" > "$SRC.tmp"
            mv "$SRC.tmp" "$SRC"
            ;;
    esac
    mv -v "$SRC" "$F"
done
    """.format(
        maybe_install_erlang = maybe_install_erlang(ctx),
        erlang_home = erlang_home,
        out_dirs = " ".join(unique_dirnames(outputs)),
        out_files = " ".join([f.path for f in outputs]),
        erl_libs_path = "",
        include_args = " ".join(include_args),
    )

    inputs = depset(
        direct = ctx.files.srcs + ctx.files.incs,
        transitive = [runfiles.files],
    )

    ctx.actions.run_shell(
        inputs = inputs,
        outputs = outputs,
        command = script,
        arguments = ctx.attr.erlc_opts + [srcs],
        mnemonic = "ERLCASN1",
    )

    return [
        DefaultInfo(files = depset(outputs)),
    ]

erlang_asn1 = rule(
    implementation = _impl,
    attrs = {
        "app_name": attr.string(),
        "srcs": attr.label_list(
            mandatory = True,
            allow_files = [".asn", ".asn1"],
        ),
        "incs": attr.label_list(
            allow_files = [".asn", ".asn1"],
        ),
        "deps": attr.label_list(
            providers = [ErlangAppInfo],
        ),
        "erlc_opts": attr.string_list(),
        "outs": attr.output_list(
            mandatory = True,
        ),
    },
    toolchains = ["//tools:toolchain_type"],
)
