# Custom RBE platform using BuildBuddy's Ubuntu base with OCaml/opam added
platform(
    name = "rbe_platform",
    constraint_values = [
        "@platforms//cpu:x86_64",
        "@platforms//os:linux",
        "@bazel_tools//tools/cpp:gcc",
    ],
    exec_properties = {
        "OSFamily": "Linux",
        "Arch": "amd64",
        "dockerNetwork": "off",
        "container-image": "docker://ghcr.io/carverauto/serviceradar/rbe-executor:v1.0.9",
    },
    visibility = ["//visibility:public"],
)

# RBE execution platform specialized for rules_ocaml native toolchain actions.
platform(
    name = "ocaml_rbe_ocamlopt",
    constraint_values = [
        "@rules_ocaml//platform/arch:sys",
        "@rules_ocaml//platform/executor:sys",
        "@rules_ocaml//platform/emitter:sys",
    ],
    parents = ["//docker:rbe_platform"],
    visibility = ["//visibility:public"],
)

# RBE execution platform specialized for rules_ocaml bytecode toolchain actions.
platform(
    name = "ocaml_rbe_ocamlc",
    constraint_values = [
        "@rules_ocaml//platform/arch:sys",
        "@rules_ocaml//platform/executor:sys",
        "@rules_ocaml//platform/emitter:vm",
    ],
    parents = ["//docker:rbe_platform"],
    visibility = ["//visibility:public"],
)
