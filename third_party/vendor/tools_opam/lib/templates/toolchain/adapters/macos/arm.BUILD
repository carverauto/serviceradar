# generated file - DO NOT EDIT

exports_files(["BUILD.bazel"])

## toolchains where buildhost == macos/x86_64

load("@rules_ocaml//toolchain:BUILD.bzl", "ocaml_toolchain_adapter")

######## toolchain adapters ########

ocaml_toolchain_adapter(
    name                   = "vm",
    host                   = "macos_x86_64",
    target                 = "vm",
    repl                   = "@ocaml//bin:ocaml",
    compiler               = "@ocaml//bin:ocamlc.opt",
    profiling_compiler     = "@ocaml//bin:ocamlcp",
    ocamllex               = "@ocaml//bin:ocamllex.opt",
    ocamlyacc              = "@ocaml//bin:ocamlyacc",
    linkmode               = "dynamic",
    vmruntime              = "@ocaml//bin:ocamlrun",
    vmruntime_debug        = "@ocaml//bin:ocamlrund",
    vmruntime_instrumented = "@ocaml//bin:ocamlruni",
    dllibs                 = "@stublibs//stublibs",
)

ocaml_toolchain_adapter(
    name                   = "macos_x86_64",
    host                   = "macos_x86_64",
    target                 = "macos_x86_64",
    repl                   = "@ocaml//bin:ocaml",
    compiler               = "@ocaml//bin:ocamlopt.opt",
    profiling_compiler     = "@ocaml//bin:ocamloptp",
    ocamllex               = "@ocaml//bin:ocamllex.opt",
    ocamlyacc              = "@ocaml//bin:ocamlyacc",
    linkmode               = "dynamic",
    vmruntime              = "@ocaml//bin:ocamlrun",
    vmruntime_debug        = "@ocaml//bin:ocamlrund",
    vmruntime_instrumented = "@ocaml//bin:ocamlruni",
    dllibs                 = "@stublibs//stublibs",
)

ocaml_toolchain_adapter(
    name                   = "linux_x86_64",
    host                   = "macos_x86_64",
    target                 = "linux_x86_64",
    ## fake tools
    repl                   = "@ocaml//bin:ocaml",
    compiler               = "@ocaml//bin:ocamlopt.opt",
    profiling_compiler     = "@ocaml//bin:ocamloptp",
    ocamllex               = "@ocaml//bin:ocamllex.opt",
    ocamlyacc              = "@ocaml//bin:ocamlyacc",
    linkmode               = "dynamic",
    vmruntime              = "@ocaml//bin:ocamlrun",
    vmruntime_debug        = "@ocaml//bin:ocamlrund",
    vmruntime_instrumented = "@ocaml//bin:ocamlruni",
    dllibs                 = "@stublibs//stublibs",
)
