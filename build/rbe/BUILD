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
        "container-image": "docker://registry.carverauto.dev/serviceradar/rbe-executor:v1.0.24.1",
        # Firecracker microVM size, matching //build/platforms:rbe_linux_amd64.
        #
        # These belong here rather than in .bazelrc. `--remote_default_exec_properties`
        # applies only when the execution platform sets NO exec_properties at all, and this
        # platform sets four above, so the flag was silently ignored for every action built
        # with --config=ci or --config=remote. Actions fell back to the executor's
        # default_task_size (~2 GiB) instead of the 8 GiB that was intended, which is what
        # left rustc+ld and pure-Go GoLink dying on signal 9 (see #4752/#4755) and forced
        # individual targets to name test.EstimatedMemory to get anything larger.
        #
        # Note it is all-or-nothing, not per key: adding one exec_property to a platform
        # discards the whole default set.
        "EstimatedCPU": "4",
        "EstimatedMemory": "8Gi",
    },
    visibility = ["//visibility:public"],
)
