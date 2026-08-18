# Custom RBE platform for the BuildBuddy executor fleet.
#
# The action image is Ubuntu 24.04 (//docker/Dockerfile.rbe).
#
# This is the platform //.bazelrc actually references, and now the only one. Two rival
# definitions have since been removed rather than reconciled: a second `rbe_platform` in the
# root //BUILD.bazel that claimed clang for a gcc image (see the note left in its place), and
# the `rbe_linux_amd64` / `rbe_linux_arm64` pair in //build/platforms, orphaned in September
# 2025 and maintained for ten months after. Edit this one.
#
# DELIBERATELY NO EstimatedCPU / EstimatedMemory.
#
# BuildBuddy sizes each task from measured history; an explicit exec_property OVERRIDES
# that predictor. One hand-written number applied to every action in the repo is strictly
# worse than a per-action measurement, and because a task's size decides how many fit on
# an executor, an over-large default throttles the whole fleet: at 4 CPU / 8Gi against
# executors requesting 8 CPU / 16Gi only 2 actions ran per executor, so a 3-executor fleet
# managed ~6 while `--jobs=100` queued the rest.
#
# The floor stays cluster-side in //k8s/buildbuddy/values.yaml (`default_task_size`,
# 2 CPU / 2 GiB), which is where it belongs -- it exists to stop a Firecracker microVM
# being too small to unpack its own initrd, and can be lowered once Firecracker is gone.
# Note `default_isolation_type` is already `oci`, so most actions never boot a VM.
#
# If an action is mis-sized, give THAT target exec_properties. Do not reintroduce a
# platform-wide default: it costs concurrency on every action in the repo to fix one.
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
        "container-image": "docker://registry.carverauto.dev/serviceradar/rbe-executor:v1.0.25.1",
    },
    visibility = ["//visibility:public"],
)
