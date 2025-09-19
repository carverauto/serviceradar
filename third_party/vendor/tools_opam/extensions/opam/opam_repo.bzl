load("@bazel_skylib//lib:paths.bzl", "paths")

load("opam_dep.bzl", "OBAZL_PKGS")
load("opam_ops.bzl", "opam_install_pkg",
     "print_cwd", "print_tree", "run_cmd")

arch_map = {
    "x86": "i686",
    "x86_64": "x86_64",
    "amd64": "x86_64",
    "aarch64_be": "arm64",
    "aarch64": "arm64",

    #ppcle|ppc64le) ARCH="ppc64le";;
    #s390x) ARCH="s390x";;
    # armv5*|armv6*|earmv6*|armv7*|earmv7*| "armhf"
    "armv8b": "armhf",
    "armv8l": "armhf"
}

os_map = {
    "mac os x": "macos",
    "linux": "linux"
}

###################
def utop_get_paths(rctx, opambin, opam_root, switch_id,
                  debug, verbosity, opam_verbosity):
    cmd = [opambin, "var", "bin",
           "--switch", "{}".format(switch_id),
           "--root", opam_root]
    res = rctx.execute(cmd, quiet = (opam_verbosity < 1))
    if res.return_code == 0:
        switch_bin = res.stdout.strip()
    else:
        print("cmd: %s" % cmd)
        print("rc: %s" % res.return_code)
        print("stdout: %s" % res.stdout)
        print("stderr: %s" % res.stderr)
        fail("cmd failure")

    utop_path = switch_bin + "/utop"
    if not rctx.path(utop_path).exists:
        utop_path = None
        # fail("utop executable not found: %s" % utop_path)

    cmd = [opambin, "var", "stublibs",
           "--switch", "{}".format(switch_id),
           "--root", opam_root]
    res = rctx.execute(cmd, quiet = (opam_verbosity < 1))
    if res.return_code == 0:
        stublibs = res.stdout.strip()
    else:
        print("cmd: %s" % cmd)
        print("rc: %s" % res.return_code)
        print("stdout: %s" % res.stdout)
        print("stderr: %s" % res.stderr)
        fail("cmd failure")

    if not rctx.path(stublibs).exists:
        fail("utop stublibs not found: %s" % stublibs)

    cmd = [opambin, "var", "ocaml:lib",
           "--switch", "{}".format(switch_id),
           "--root", opam_root]
    res = rctx.execute(cmd, quiet = (opam_verbosity < 1))
    if res.return_code == 0:
        ocaml_stublibs = res.stdout.strip() + "/stublibs"
    else:
        print("cmd: %s" % cmd)
        print("rc: %s" % res.return_code)
        print("stdout: %s" % res.stdout)
        print("stderr: %s" % res.stderr)
        fail("cmd failure")

    if not rctx.path(ocaml_stublibs).exists:
        fail("utop ocaml stublibs not found: %s" % ocaml_stublibs)

    return utop_path, stublibs, ocaml_stublibs

##############################
def _opam_repo_impl(rctx):
    # if tc == local: created if needed, symlink
    # elif tc == global, symlink to opam binary & root
    # else: embedded, proceed as follows:

    rctx.file("REPO.bazel", content = "")

    rctx.file(
        "MODULE.bazel",
        content = """
module(
    name = "opam",
    version = "{}",
)
bazel_dep(name = "rules_cc", version = "0.1.1")
        """.format(rctx.attr.opam_version)
    )

    opam_bindir = paths.dirname(rctx.attr.opam_bin)

    rctx.template("opam_runner.c",
                  rctx.attr._opam_runner)

    rctx.file("BUILD.bazel",
        content = """
load("@rules_cc//cc:defs.bzl", "cc_binary")
ARGS = ["--root", "{root}", "--switch", "{switch}"]
ENV = {{"OPAMBINDIR": "{bin}",
        "OPAMROOT": "{root}",
        "OPAMSWITCH": "{switch}",
        "ROOTMODULE": "{root_module}"}}

alias(name = "opam", actual=":opam_runner")

cc_binary(
    name = "opam_runner",
    srcs = ["opam_runner.c"],
    copts = ["-Wno-null-character"],
    args = ["{bin}/opam"],
    env  = ENV,
    # data = ["{bin}"]
)

        """.format(root   = rctx.attr.opam_root,
                   switch = rctx.attr.switch_id,
                   bin    = opam_bindir,
                   root_module = rctx.attr.root_module)
              )

    utop_bin, stublibs, ocaml_stublibs = utop_get_paths(
        rctx, rctx.attr.opam_bin,
        rctx.attr.opam_root,
        rctx.attr.switch_id,
        rctx.attr.debug,
        rctx.attr.verbosity,
        rctx.attr.opam_verbosity)

    ld_lib_path = stublibs + ":" + ocaml_stublibs

    rctx.file("config/BUILD.bazel", content = "")
    rctx.file("config/defs.bzl",
              content = """
OPAMBINDIR = "{opambin}"
OPAMROOT   = "{opamroot}"
OPAMSWITCH = "{opamswitch}"
CAML_LD_LIBRARY_PATH = "{ld_path}"
              """.format(
                  opambin    = opam_bindir,
                  opamroot   = rctx.attr.opam_root,
                  opamswitch = rctx.attr.switch_id,
                  ld_path    = ld_lib_path
              )
              )

    rctx.template("reconfig/reconfig.c",
                  rctx.attr._reconfig_runner)


    rctx.file("reconfig/BUILD.bazel",
        content = """
load("@rules_cc//cc:defs.bzl", "cc_binary")
ARGS = ["--root", "{root}", "--switch", "{switch}"]
ENV = {{"OPAMBINDIR": "{bin}",
        "OPAMROOT": "{root}",
        "OPAMSWITCH": "{switch}",
        "CONFIGFILE": "{config_file}",
        "ROOTMODULE": "{root_module}"}}

cc_binary(
    name = "reconfig",
    srcs = ["reconfig.c"],
    copts = ["-Wno-null-character"],
    args = ["{bin}/opam", "--config=../tools_opam+/extensions/{config_file_name}"],
    env  = ENV,
    data = ["{config_file}"]
)
        """.format(root   = rctx.attr.opam_root,
                   switch = rctx.attr.switch_id,
                   bin    = opam_bindir,
                   config_file = rctx.attr.config_file,
                   config_file_name = rctx.attr.config_file.name,
                   root_module = rctx.attr.root_module.name)
              )

    #### REINIT ####
    rctx.template("reinit/reinit.c",
                  rctx.attr._reinit_runner)

    rctx.file("reinit/BUILD.bazel",
        content = """
load("@rules_cc//cc:defs.bzl", "cc_binary")
ARGS = ["--root", "{root}", "--switch", "{switch}"]
ENV = {{"OPAMBINDIR": "{bin}",
        "OPAMROOT": "{root}",
        "OPAMSWITCH": "{switch}",
        "ROOTMODULE": "{root_module}"}}

cc_binary(
    name = "reinit",
    srcs = ["reinit.c"],
    copts = ["-Wno-null-character"],
    args = ["{bin}/opam"],
    env  = ENV
)
        """.format(root   = rctx.attr.opam_root,
                   switch = rctx.attr.switch_id,
                   bin    = opam_bindir,
                   root_module = rctx.attr.root_module)
              )

    ################

    root = rctx.path("./.opam")
    rctx.symlink(rctx.attr.opam_bin, "opam.exe")

###############################
opam_repo = repository_rule(
    implementation = _opam_repo_impl,
    attrs = {
        "root_module": attr.label(),
        "opam_bin": attr.string(),
        "opam_version": attr.string(),
        "opam_root": attr.string(),
        "config_file": attr.label(),
        "switch_id": attr.string(),
        "_opam_runner": attr.label(
            default = "opam_runner.c"
        ),
        "_reconfig_runner": attr.label(
            default = "opam_reconfig.c"
        ),
        "_reinit_runner": attr.label(
            default = "opam_reinit.c"
        ),
        "debug": attr.int(default=0),
        "verbosity": attr.int(default=0),
        "opam_verbosity": attr.int(default=0)
    },
)
