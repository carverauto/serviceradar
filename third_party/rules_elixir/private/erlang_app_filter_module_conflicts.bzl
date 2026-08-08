load("@bazel_skylib//lib:shell.bzl", "shell")
load("@rules_erlang//:erlang_app_info.bzl", "ErlangAppInfo")

def _impl(ctx):
    lib_info = ctx.attr.src[ErlangAppInfo]
    if len(lib_info.beam) != 1:
        fail("src must have beam_files that are a single directory")
    if not lib_info.beam[0].is_directory:
        fail("src must have beam_files that are a single directory")

    new_beam_files = ctx.actions.declare_directory(ctx.attr.dest)

    ctx.actions.run_shell(
        inputs = lib_info.beam + ctx.files.without,
        outputs = [new_beam_files],
        command = """set -euo pipefail

cp "{beam_files_dir}"/* "{new_beam_files_dir}"

without={without}
without_modules=()
for f in ${{without[@]}}; do
    if [[ -d "$f" ]]; then
        for m in "$f"/*.beam; do
            without_modules+=( $(basename "$m") )
        done
    else
        without_modules+=( $(basename "$f") )
    fi
done
for m in ${{without_modules[@]}}; do
    if [[ -f "{new_beam_files_dir}/$m" ]]; then
        echo "Removing $m"
        rm "{new_beam_files_dir}/$m"
    fi
done
""".format(
            beam_files_dir = lib_info.beam[0].path,
            new_beam_files_dir = new_beam_files.path,
            without = shell.array_literal([
                f.path
                for f in ctx.files.without
            ]),
        ),
    )

    runfiles = ctx.runfiles([new_beam_files])
    for dep in lib_info.deps:
        runfiles = runfiles.merge(dep[DefaultInfo].default_runfiles)

    return [
        DefaultInfo(
            files = depset([new_beam_files]),
            runfiles = runfiles,
        ),
        ErlangAppInfo(
            app_name = lib_info.app_name,
            include = lib_info.include,
            beam = [new_beam_files],
            priv = lib_info.priv,
            license_files = lib_info.license_files,
            srcs = lib_info.srcs,
            deps = lib_info.deps,
        ),
    ]

erlang_app_filter_module_conflicts = rule(
    implementation = _impl,
    attrs = {
        "src": attr.label(
            providers = [ErlangAppInfo],
        ),
        "without": attr.label_list(
            allow_files = [".beam"],
        ),
        "dest": attr.string(
            default = "ebin",
        ),
    },
    provides = [ErlangAppInfo],
)
