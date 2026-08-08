def _impl(ctx):
    out = ctx.actions.declare_directory(ctx.attr.dest)

    if len(ctx.files.beam_files_dir) != 1:
        fail("ebin attr must reference a single directory")
    if not ctx.files.beam_files_dir[0].is_directory:
        fail("ebin attr must reference a single directory")

    ctx.actions.run_shell(
        inputs = ctx.files.beam_files_dir + ctx.files.app_file,
        outputs = [out],
        command = """set -euo pipefail

cp -r "{beam_files_dir}"/* "{out}"
cp "{app_file}" "{out}"
""".format(
            beam_files_dir = ctx.files.beam_files_dir[0].path,
            app_file = ctx.file.app_file.path,
            out = out.path,
        ),
    )

    return [DefaultInfo(files = depset([out]))]

elixir_ebin_dir = rule(
    implementation = _impl,
    attrs = {
        "beam_files_dir": attr.label(
            allow_files = True,
        ),
        "app_file": attr.label(
            allow_single_file = [".app"],
        ),
        "dest": attr.string(
            default = "ebin",
        ),
    },
)
