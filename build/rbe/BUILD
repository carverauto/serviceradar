# Custom RBE platform for Oracle Linux based BuildBuddy executor
platform(
    name = "rbe_platform",
    constraint_values = [
        "@platforms//cpu:x86_64",
        "@platforms//os:linux",
        "@bazel_tools//tools/cpp:gcc",
        "@rules_pkg//pkg:not_compatible",
    ],
    exec_properties = {
        "OSFamily": "Linux",
        "Arch": "amd64",
        "dockerNetwork": "host",
        "container-image": "docker://ghcr.io/carverauto/serviceradar/rbe-executor:v1.0.13",
    },
    visibility = ["//visibility:public"],
)
