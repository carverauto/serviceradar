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
        "container-image": "docker://ghcr.io/carverauto/serviceradar/rbe-executor:latest",
    },
    visibility = ["//visibility:public"],
)