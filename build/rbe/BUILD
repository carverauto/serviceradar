# Custom RBE platform for Oracle Linux based BuildBuddy executor
platform(
    name = "rbe_platform",
    constraint_values = [
        "@platforms//cpu:x86_64",
        "@platforms//os:linux",
        "@bazel_tools//tools/cpp:gcc",
        "@erlang_config//:erlang_internal",
        "@elixir_config//:elixir_internal",
    ],
    exec_properties = {
        "OSFamily": "Linux",
        "Arch": "amd64",
        "dockerNetwork": "host",
        "container-image": "docker://registry.carverauto.dev/serviceradar/rbe-executor:v1.0.23",
        # Firecracker isolation (#4752) sizes VMs from these estimates. Rust
        # link (anomaly-addon) and pure-Go GoLink need ~8Gi class VMs.
        "EstimatedCPU": "4",
        "EstimatedMemory": "8GB",
    },
    visibility = ["//visibility:public"],
)
