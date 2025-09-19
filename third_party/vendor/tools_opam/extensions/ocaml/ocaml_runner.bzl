def _ocaml_runner_impl(ctx):

    runner = ctx.actions.declare_file("ocaml")
    ctx.actions.symlink(
        output = runner,
        target_file = ctx.file._bin,
        is_executable = True)

    rtEnvInfo = RunEnvironmentInfo(
        environment = ctx.attr.env
    )

    runfiles = ctx.runfiles(
        files = ctx.files._bin + ctx.files.data
    )

    defaultInfo = DefaultInfo(
        executable = runner,
        runfiles   = runfiles
    )

    return [defaultInfo, rtEnvInfo]

ocaml_runner = rule(
    implementation = _ocaml_runner_impl,
    doc = "Runs ocaml.",
    executable = True,
    attrs = dict(
        data = attr.label_list(
            allow_files = True,
        ),
        env = attr.string_dict(
            doc = "Env variables",
            allow_empty = True
        ),
        _bin = attr.label(
            doc = "Bazel label of ocaml executable.",
            allow_single_file = True,
            default = "@opam.ocamlsdk//bin:ocaml"
        ),
    )
)
