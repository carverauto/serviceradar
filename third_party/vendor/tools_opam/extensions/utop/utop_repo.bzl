# load("//extensions:opam_ops.bzl",
#      "print_cwd", "print_tree", "run_cmd")

##############################
def _utop_repo_impl(rctx):
    # if tc == local: created if needed, symlink
    # elif tc == global, symlink to opam binary & root
    # else: embedded, proceed as follows:

    rctx.file("REPO.bazel", content = "")

    rctx.file(
        "MODULE.bazel",
        content = """
module(
    name = "utop",
    version = "{}",
)
bazel_dep(name = "rules_cc", version = "0.1.1")
        """.format(rctx.attr.utop_version)
    )

    rctx.template("utop_runner.c",
                  rctx.attr._utop_runner)

    if rctx.attr.ocamlinit:
        ## FIXME: verify exists
        ocamlinit = "'" + str(rctx.attr.ocamlinit) + "'"
    else:
        ocamlinit = ""

    rctx.file("BUILD.bazel",
        content = """
load("@rules_cc//cc:defs.bzl", "cc_binary")

alias(name = "utop", actual="utop_runner")
alias(name = "opam.utop", actual="utop_runner")

cc_binary(
    name = "utop_runner",
    srcs = ["utop_runner.c"],
    copts = ["-Wno-null-character"],
    args = ["{utopbin}"],
    data = [{ocamlinit}],
    env  = {{
        "OPAMBIN": "{opambin}",
        "OPAMROOT": "{root}",
        "OPAMSWITCH": "{switch}",
        "OCAML_TOPLEVEL_PATH": "",
        "CAML_LD_LIBRARY_PATH": "{ld_path}"}},
)
        """.format(
            utopbin = rctx.attr.utop_bin,
            ocamlinit = ocamlinit,
            ld_path = rctx.attr.ld_lib_path,
            opambin = rctx.attr.opam_bin,
            root = rctx.attr.opam_root,
            switch = rctx.attr.switch_id
        )
              )

    ################

    # root = rctx.path("./.opam")
    # rctx.symlink(rctx.attr.opam_bin, "opam.exe")

###############################
utop_repo = repository_rule(
    implementation = _utop_repo_impl,
    attrs = {
        "root_module": attr.label(),
        "utop_bin": attr.string(
            mandatory = True
        ),
        "ld_lib_path": attr.string(
            mandatory = True
        ),
        "utop_version": attr.string(),
        "opam_bin": attr.string(),
        "opam_root": attr.string(),
        "ocamlinit": attr.label(),
        "switch_id": attr.string(),
        "_utop_runner": attr.label(
            default = "utop_runner.c"
        ),
        "debug": attr.int(default=0),
        "verbosity": attr.int(default=0)
    },
)
