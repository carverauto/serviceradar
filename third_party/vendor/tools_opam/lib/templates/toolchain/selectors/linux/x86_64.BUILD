# generated file - DO NOT EDIT

## @ocaml//toolchain/selectors/linux/x86_64:<target>
## Selectors for target variants where buildhost = linux/x86_64

exports_files(glob(["*.bazel"]))

##########
toolchain(
    name           = "vm",
    toolchain      = "@ocaml//toolchain/adapters/linux/x86_64:vm",
    toolchain_type = "@rules_ocaml//toolchain/type:std",
    exec_compatible_with = [
        "@platforms//os:linux",
        "@platforms//cpu:x86_64",
    ],
    target_compatible_with = [
        "@ocaml//platforms:vm?",
    ],
    visibility             = ["//visibility:public"],
)

##########
toolchain(
    name           = "linux_x86_64",
    toolchain      = "@ocaml//toolchain/adapters/linux/x86_64:linux_x86_64",
    toolchain_type = "@rules_ocaml//toolchain/type:std",
    exec_compatible_with = [
        "@platforms//os:linux",
        "@platforms//cpu:x86_64",
    ],
    target_compatible_with = [
        "@platforms//os:linux",
        "@platforms//cpu:x86_64",
    ],
    visibility             = ["//visibility:public"],
)

##########
# We can select this with
# --host_platform=@ocaml//platforms:linux_x86_64
# --platforms=@ocaml//platforms:macos_x86_64
# but CC toolchain selection will fail since we do not have a
# cross-compiling cc toolchain.
toolchain(
    name           = "macos_x86_64",
    toolchain      =
    "@ocaml//toolchain/adapters/linux/x86_64:macos_x86_64",
    toolchain_type = "@rules_ocaml//toolchain/type:std",
    exec_compatible_with = [
        "@platforms//os:linux",
        "@platforms//cpu:x86_64",
    ],
    target_compatible_with = [
        "@platforms//os:macos",
        "@platforms//cpu:x86_64",
    ],
    visibility             = ["//visibility:public"],
)
