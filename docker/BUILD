load("@platforms//host:extension.bzl", "host_platform")

# Custom RBE platform using Oracle Linux 9 based executor image
platform(
    name = "rbe_platform",
    constraint_values = [
        "@platforms//cpu:x86_64",
        "@platforms//os:linux",
        "@bazel_tools//tools/cpp:clang",
    ],
    exec_properties = {
        "OSFamily": "Linux",
        "dockerNetwork": "off",
        "container-image": "docker://ghcr.io/carverauto/serviceradar/rbe-executor:latest",
    },
    visibility = ["//visibility:public"],
)