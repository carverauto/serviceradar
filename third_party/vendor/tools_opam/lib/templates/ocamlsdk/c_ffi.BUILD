# generated file - DO NOT EDIT

package(default_visibility = ["//visibility:public"])

alias(name = "lib", actual = ":ffi")

cc_library(
    name = "ffi",
    hdrs = glob(["caml/**"]),
    includes = ["."]
)

cc_library(
    name = "dbg",
    hdrs = glob(["caml/**"]),
    includes = ["."],
    defines = ["RUNTIME_VARIANT_DEBUG"]
)

cc_library(
    name = "instrumented",
    hdrs = glob(["caml/**"]),
    includes = ["."],
    defines = ["RUNTIME_VARIANT_INSTRUMENTED"]
)
