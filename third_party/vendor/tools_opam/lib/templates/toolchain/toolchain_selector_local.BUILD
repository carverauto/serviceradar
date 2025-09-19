# generated file - DO NOT EDIT

load("@rules_ocaml//toolchain:BUILD.bzl", "toolchain_selector")

exports_files(glob(["*.bazel"]))

################ endocompilers first ################

###################
toolchain_selector(
    name      = "ocamlopt.opt.endo",
    toolchain = "@opam.ocamlsdk//toolchain/adapters/local:ocamlopt.opt",
    build_host_constraints  = [
        "@rules_ocaml//platform/arch:sys",
        "@rules_ocaml//platform/executor:sys",
        "@rules_ocaml//platform/emitter:sys"
    ],
    target_host_constraints  = [
        "@rules_ocaml//platform/arch:sys",
        "@rules_ocaml//platform/executor:sys",
        # "@rules_ocaml//platform/emitter:sys"
    ],
    toolchain_constraints = [
        "@opam.ocamlsdk//runtime:std?"
    ],
    visibility     = ["//visibility:public"],
)

toolchain_selector(
    name      = "ocamlopt.opt.endo.d",
    toolchain = "@opam.ocamlsdk//toolchain/adapters/local:ocamlopt.opt.d",
    build_host_constraints  = [
        "@rules_ocaml//platform/arch:sys",
        "@rules_ocaml//platform/executor:sys",
        "@rules_ocaml//platform/emitter:sys"
    ],
    target_host_constraints  = [
        "@rules_ocaml//platform/arch:sys",
        "@rules_ocaml//platform/executor:sys",
        # "@rules_ocaml//platform/emitter:sys"
    ],
    toolchain_constraints = [
        "@opam.ocamlsdk//runtime:dbg?"
    ],
    visibility     = ["//visibility:public"],
)

toolchain_selector(
    name      = "ocamlopt.opt.endo.i",
    toolchain = "@opam.ocamlsdk//toolchain/adapters/local:ocamlopt.opt.d",
    build_host_constraints  = [
        "@rules_ocaml//platform/arch:sys",
        "@rules_ocaml//platform/executor:sys",
        "@rules_ocaml//platform/emitter:sys"
    ],
    target_host_constraints  = [
        "@rules_ocaml//platform/arch:sys",
        "@rules_ocaml//platform/executor:sys",
        # "@rules_ocaml//platform/emitter:sys"
    ],
    toolchain_constraints = [
        "@opam.ocamlsdk//runtime:instrumented?"
    ],
    visibility     = ["//visibility:public"],
)

##########
toolchain_selector(
    name      = "ocamlc.byte.endo",
    toolchain = "@opam.ocamlsdk//toolchain/adapters/local:ocamlc.byte",
    build_host_constraints  = [
        "@rules_ocaml//platform/arch:sys",
        "@rules_ocaml//platform/executor:vm",
        "@rules_ocaml//platform/emitter:vm"
    ],
    target_host_constraints  = [
        "@rules_ocaml//platform/arch:sys",
        "@rules_ocaml//platform/executor:vm"
    ],
    toolchain_constraints = [
        "@opam.ocamlsdk//runtime:std?"
    ],
    visibility              = ["//visibility:public"],
)

################ now exocompilers ################

###################
toolchain_selector(
    name      = "ocamlc.opt.exo",
    toolchain = "@opam.ocamlsdk//toolchain/adapters/local:ocamlc.opt",
    build_host_constraints  = [
        "@rules_ocaml//platform/arch:sys",
        "@rules_ocaml//platform/executor:sys",
        "@rules_ocaml//platform/emitter:vm"
    ],
    target_host_constraints  = [
        "@rules_ocaml//platform/arch:sys",
        "@rules_ocaml//platform/executor:vm",
    ],
    visibility              = ["//visibility:public"],
)

##########
toolchain_selector(
    name      = "ocamlopt.byte.exo",
    toolchain = "@opam.ocamlsdk//toolchain/adapters/local:ocamlopt.byte",
    build_host_constraints    = [
        "@rules_ocaml//platform/arch:sys",
        "@rules_ocaml//platform/executor:vm",
        "@rules_ocaml//platform/emitter:sys"
    ],
    target_host_constraints  = [
        "@rules_ocaml//platform/arch:sys",
        "@rules_ocaml//platform/executor:sys"
    ],
    visibility              = ["//visibility:public"],
)

################ last, "tool" endocompilers ################
## These are exo-endo-compilers, so to speak.
## These will be selected for toolchain transition
## where buildhost is an exocompiler, no matter the targethost

## codeps need cmxa archives for ocamlopt.byte,
## so we cheat, and build tools for the target,
## not the build host
## iow, according to bazel's tc transitions, the target
## here should be the build host, which has executor vm
## but ocaml_imports select on the emitter, not the executor,
## and the tc transition sets emitter to sys,
## so linking would fail if we used a vm emitter (e.g. ocamlc.opt)

## IOW we do the opposite of what bazel wants. We need
## to do this to accomodate codeps, which must *not*
## be built for the buildhost env, but for the target.
## NB: cfg = "target" on ppx_executable does not help,
## since the tc transition has already been made by the
## time the ppx_executable is evaluated, so the target
## will be same as build host due to tc transition.
toolchain_selector(
    name                    = "ocamlopt.byte.endo",
    toolchain               = "@opam.ocamlsdk//toolchain/adapters/local:ocamlopt.byte",
    build_host_constraints    = [
        "@rules_ocaml//platform/arch:sys",
        "@rules_ocaml//platform/executor:vm",
        "@rules_ocaml//platform/emitter:sys"
    ],
    target_host_constraints  = [
        "@rules_ocaml//platform/arch:sys",
        ## FAKE: target executor is sys (=build emitter), but
        ## toolchain transition makes build and target equal
        ## critical point is the emitter is used to select
        ## opam deps
        "@rules_ocaml//platform/executor:vm",
        "@rules_ocaml//platform/emitter:sys"
    ],
    visibility              = ["//visibility:public"],
)

###################
## in this case, build executor is sys so that's the (tool)
## target executor, so according to bazel we should
## use a sys emitter on the build host.
## but ocaml_import selects on the emitter here, vm
## so linking tools would fail if we used ocamlopt.opt
toolchain_selector(
    name      = "ocamlc.opt.endo",
    toolchain = "@opam.ocamlsdk//toolchain/adapters/local:ocamlc.opt",
    build_host_constraints  = [
        "@rules_ocaml//platform/arch:sys",
        "@rules_ocaml//platform/executor:sys",
        "@rules_ocaml//platform/emitter:vm"
    ],
    target_host_constraints  = [
        "@rules_ocaml//platform/arch:sys",
        "@rules_ocaml//platform/executor:sys",
        "@rules_ocaml//platform/emitter:vm"
    ],
    visibility              = ["//visibility:public"],
)

# ##########
# toolchain_selector(
#     name           = "_vm", # *>vm
#     toolchain      = "@opam.ocamlsdk//toolchain/adapters/local:ocamlc.opt",
#     target_host_constraints  = ["@rules_ocaml//platform/executor:vm"],
#     visibility     = ["//visibility:public"],
# )

# ##########
# toolchain_selector(
#     name           = "__", # *>*
#     toolchain      = "@opam.ocamlsdk//toolchain/adapters/local:ocamlopt.opt",
#     visibility     = ["//visibility:public"],
# )
