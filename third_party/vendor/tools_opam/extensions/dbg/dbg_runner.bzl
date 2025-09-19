################################################
def _dbg_out_transition_impl(settings, attr):

    ## force bytecode target, dbg build
    host = "@rules_ocaml//platform:ocamlc.opt"
    tgt  = "@rules_ocaml//platform:ocamlc.opt"

    return {
        "@rules_ocaml//toolchain": "ocamlc",
        "//command_line_option:host_platform": host,
        "//command_line_option:platforms": tgt,
        "//command_line_option:compilation_mode": "dbg"
    }

################
_dbg_out_transition = transition(
    implementation = _dbg_out_transition_impl,
    inputs = [],
    outputs = [
        "@rules_ocaml//toolchain",
        "//command_line_option:host_platform",
        "//command_line_option:platforms",
        "//command_line_option:compilation_mode"
    ]
)



def _ocamldebug_runner_impl(ctx):

    # if ctx.attr.pgm.label == Label("@dbg//pgm:dummy"):

    runner = ctx.actions.declare_file("ocamldebug")
    ctx.actions.symlink(
        output = runner,
        target_file = ctx.file.runner,
        is_executable = True)

    e = {"OCAMLDEBUG": ctx.file.bin.short_path,
         "OBAZL_DEBUG_TGT": ctx.file.pgm.short_path}
    e.update(ctx.attr.env)

    rtEnvInfo = RunEnvironmentInfo(
        environment = e
    )

    runfiles = ctx.runfiles(
        files = ctx.files.bin + ctx.files.pgm + ctx.files.data
    )

    defaultInfo = DefaultInfo(
        executable = runner,
        runfiles   = runfiles
    )

    return [defaultInfo, rtEnvInfo]

ocamldebug_runner = rule(
    implementation = _ocamldebug_runner_impl,
    doc = "Runs ocamldebug.",
    executable = True,
    attrs = dict(
        data = attr.label_list(
            allow_files = True,
        ),
        env = attr.string_dict(
            doc = "Env variables",
            allow_empty = True
        ),
        runner = attr.label(
            allow_single_file = True,
            executable = True,
            mandatory = True,
            cfg = "exec"
        ),
        bin = attr.label(
            doc = "Bazel label of ocamldebug executable.",
            mandatory = True,
            allow_single_file = True,
            default = "@opam.ocamlsdk//bin:ocamldebug"
        ),
        pgm = attr.label(
            # mandatory = True,
            default = "@dbg//pgm",
            allow_single_file = True,
            cfg = _dbg_out_transition
        ),
        _allowlist_function_transition = attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist"
        ),
    )
)
