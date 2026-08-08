load(
    "//:erlang_app_info.bzl",
    "ErlangAppInfo",
    "flat_deps",
)

def _module_name(f):
    return f.basename.replace(".beam", "")

def _impl(ctx):
    apps = flat_deps(ctx.attr.apps)

    index = {}
    for app in apps:
        info = app[ErlangAppInfo]
        index[info.app_name] = [
            _module_name(b)
            for b in info.beam
            if b.basename.endswith(".beam")
        ]

    yaml = ""
    for app in sorted(index.keys()):
        yaml += app + ":\n"
        for module in sorted(index[app]):
            yaml += "- " + module + "\n"
    yaml = yaml.removesuffix("\n")

    ctx.actions.write(
        output = ctx.outputs.executable,
        content = """cat << EOF
{}
EOF
""".format(yaml),
        is_executable = True,
    )

moduleindex = rule(
    implementation = _impl,
    attrs = {
        "apps": attr.label_list(providers = [ErlangAppInfo]),
    },
    executable = True,
)
