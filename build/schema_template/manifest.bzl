"""Declare all schema identity inputs; never discover files in the execution root."""

def _manifest_impl(ctx):
    output = ctx.actions.declare_file(ctx.attr.out)
    args = ctx.actions.args()
    args.add("--output", output)
    groups = {
        "migration": ctx.files.migrations,
        "baseline-sql": [ctx.file.baseline_sql],
        "baseline-metadata": [ctx.file.baseline_metadata],
        "helper": ctx.files.helpers,
        "construction": ctx.files.construction,
    }
    inputs = []
    for group, files in groups.items():
        if not files:
            fail("schema manifest requires nonempty %s inputs" % group)
        for file in files:
            # short_path is checkout-independent; path is used only to open the
            # declared input in this action, and never enters the manifest.
            args.add("--" + group)
            args.add(file.short_path)
            args.add(file.path)
            inputs.append(file)
    args.use_param_file("@%s", use_always = True)
    args.set_param_file_format("multiline")
    ctx.actions.run(
        executable = ctx.executable._generator,
        arguments = [args],
        inputs = depset(inputs),
        outputs = [output],
        mnemonic = "SchemaTemplateManifest",
        progress_message = "Hashing declared schema template inputs",
    )
    return [DefaultInfo(files = depset([output]))]

schema_template_manifest = rule(
    implementation = _manifest_impl,
    attrs = {
        "migrations": attr.label_list(allow_files = True, mandatory = True),
        "baseline_sql": attr.label(allow_single_file = [".sql"], mandatory = True),
        "baseline_metadata": attr.label(allow_single_file = [".json"], mandatory = True),
        "helpers": attr.label_list(allow_files = True, mandatory = True),
        "construction": attr.label_list(allow_files = True, mandatory = True),
        "out": attr.string(default = "manifest.json"),
        "_generator": attr.label(
            default = Label("//build/schema_template:generate_manifest"),
            executable = True,
            cfg = "exec",
        ),
    },
)
