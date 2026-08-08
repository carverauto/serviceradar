

def _common_root_as_var(ctx):
    if ctx.attr.var_name != "":
        key = ctx.attr.var_name
    else:
        key = ctx.label.name.upper()

    value = ctx.files.srcs[0].dirname
    for src in ctx.files.srcs:
        if value.startswith(src.dirname):
            value = src.dirname
        elif src.dirname.startswith(value):
            pass
        elif value == src.dirname:
            pass
        else:
            fail("%s and %s do not share a common root" % (value, src.dirname))

    return [
        platform_common.TemplateVariableInfo({
            key: value,
        }),
    ]

common_root_as_var = rule(
    implementation = _common_root_as_var,
    attrs = {
        "var_name": attr.string(),
        "srcs": attr.label_list(
            allow_files = True,
            mandatory = True,
        ),
    },
)
