# load("//extensions:opam_ops.bzl",
#      "print_cwd", "print_tree", "run_cmd")

##############################
def _ocaml_repo_impl(rctx):
    # if tc == local: created if needed, symlink
    # elif tc == global, symlink to opam binary & root
    # else: embedded, proceed as follows:

    rctx.file("REPO.bazel", content = "")

    rctx.file(
        "MODULE.bazel",
        content = """
module(
    name = "ocaml",
    version = "{}",
)
bazel_dep(name = "rules_cc", version = "0.1.1")
        """.format(rctx.attr.ocaml_version)
    )

    rctx.template("ocaml_runner.c",
                  rctx.attr._ocaml_launcher)

    cmd = [rctx.attr.opam_bin, "var", "bin",
           "--switch", "{}".format(rctx.attr.switch_id),
           "--root", rctx.attr.opam_root]
    res = rctx.execute(cmd, quiet = (rctx.attr.opam_verbosity < 1))
    if res.return_code == 0:
        switch_bin = res.stdout.strip()
    else:
        print("cmd: %s" % cmd)
        print("rc: %s" % res.return_code)
        print("stdout: %s" % res.stdout)
        print("stderr: %s" % res.stderr)
        fail("cmd failure")

    ocaml_path = switch_bin + "/ocaml"
    if not rctx.path(ocaml_path).exists:
        ocaml_path = None
        # fail("utop executable not found: %s" % utop_path)

    rctx.template("ocaml_runner.bzl",
                  rctx.attr._ocaml_runner)

    rctx.file("BUILD.bazel",
        content = """
load("@rules_cc//cc:defs.bzl", "cc_binary")
load(":ocaml_runner.bzl", "ocaml_runner")

alias(name = "ocaml", actual="ocaml_runner")

cc_binary(
    name = "ocaml_runner",
    srcs = ["ocaml_runner.c"],
    copts = ["-Wno-null-character"],
    args = ["{ocamlbin}"],
    env  = {{
        "OPAMROOT": "{root}",
        "OPAMSWITCH": "{switch}",
        "OCAML_TOPLEVEL_PATH": "",
        }},
)
        """.format(
            ocamlbin = ocaml_path,
            # ocamlinit = ocamlinit,
            # ld_path = rctx.attr.ld_lib_path,
            # opambin = rctx.attr.opam_bin,
            root = rctx.attr.opam_root,
            switch = rctx.attr.switch_id
        )
              )
    ## data = [{ocamlinit}],
    ## "OPAMBIN": "{opambin}",
    ## "CAML_LD_LIBRARY_PATH": "{ld_path}"

# ocaml_runner(
#     name = "ocaml_runner",
#     env  = {{
#         "OPAMROOT": "{root}",
#         "OPAMSWITCH": "{switch}",
#         "OCAML_TOPLEVEL_PATH": "",
#         }},
# )
#         """.format(
#             # inifile = rctx.attr.ini_file,
#             # ld_path = rctx.attr.ld_lib_path,
#             root = rctx.attr.opam_root,
#             switch = rctx.attr.switch_id,
#             dbgbin = rctx.attr.ocaml_bin,
#             # ocamlinit = ocamlinit,
#             # ld_path = rctx.attr.ld_lib_path,
#             # opambin = rctx.attr.opam_bin,
#             # rf = "" # sources as runfiles
#         )
              # )
        # "CAML_LD_LIBRARY_PATH": "{ld_path}"
#        "CAML_LD_LIBRARY_PATH": "{ld_path}"}},

###############################
ocaml_repo = repository_rule(
    implementation = _ocaml_repo_impl,
    attrs = {
        "root_module": attr.label(),
        "opam_bin": attr.string(),
        "opam_root": attr.string(),
        "switch_id": attr.string(),
        # "ini_file": attr.label(),
        "ocaml_version": attr.string(),
        "_ocaml_runner": attr.label(
            default = "ocaml_runner.bzl"
        ),
        "_ocaml_launcher": attr.label(
            default = "ocaml_runner.c"
        ),
        "debug": attr.int(default=0),
        "verbosity": attr.int(default=0),
        "opam_verbosity": attr.int(default=0)
    },
)
