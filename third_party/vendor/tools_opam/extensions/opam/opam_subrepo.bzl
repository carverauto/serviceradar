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

##############################
def _opam_repo_impl(rctx):
    if rctx.attr.debug > 0: print("OPAM REPO running")

    rctx.file(
        "MODULE.bazel",
        content = """
module(
    name = "opam",
e    version = "{}",
)
        """.format(rctx.attr.opam_version)
    )

    print("opam: %s" % rctx.attr.opam)

    realopam = rctx.path(rctx.attr.opam).realpath
    print("realopam: %s" % realopam)
    if rctx.attr.debug > 0:
        print("Symlinking opam %s to bin/opam" % rctx.attr.opam)
    rctx.symlink(realopam, "./bin/opam")

    if rctx.attr.verbosity > 0:
        print_cwd(rctx)
        print_tree(rctx)
    opambin = rctx.path("./bin/opam")
    if opambin.realpath.exists:
        print("bin/opam: %s" % opambin)
    else:
        print("????????????????")

    rctx.file("bin/BUILD.bazel",
        content = """
exports_files(["opam"])
        """)

#     rctx.file("config/BUILD.bazel",
#         content = """
# exports_files(["root", "switch"])
# # load("@bazel_skylib//rules:common_settings.bzl", "string_setting")
# # string_setting(name = "root", build_setting_default = {})
# # string_setting(name = "switch", build_setting_default = {})
#         """.format(root, rctx.attr.ocaml_version))

    for pkg in rctx.attr.deps:
        opam_install_pkg(rctx,
                         opambin, # rctx.attr.opam,
                         pkg,
                         rctx.attr.ocaml_version,
                         rctx.attr.opam_root,
                         rctx.attr.debug,
                         rctx.attr.verbosity)

###############################
opam_repo = repository_rule(
    implementation = _opam_repo_impl,
    attrs = {
        "toolchain": attr.string(),
        "opam": attr.string(),
        "opam_version": attr.string(),
        "opam_root": attr.string(),
        "ocaml_version": attr.string(),
        "deps": attr.string_list(
            mandatory = True,
            allow_empty = False
        ),
        "debug": attr.int(default=0),
        "verbosity": attr.int(default=0)
    },
)
