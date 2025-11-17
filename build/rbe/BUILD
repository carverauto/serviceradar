# Custom RBE platform for Oracle Linux based BuildBuddy executor
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
        "container-image": "docker://ghcr.io/carverauto/serviceradar/rbe-executor:v1.0.11",
    },
    visibility = ["//visibility:public"],
)
