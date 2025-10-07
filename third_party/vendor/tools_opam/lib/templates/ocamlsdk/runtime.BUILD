# generated file - DO NOT EDIT

package(default_visibility = ["//visibility:public"])

exports_files(glob(["**"],
                   exclude = ["std_exit.cmo"]))

load("@bazel_skylib//rules:common_settings.bzl",
        "string_flag", "string_setting")

# load("@rules_ocaml//build:rules.bzl", "ocaml_import")

string_flag(
    name = "runtime",
    values = ["std", "pic", "dbg", "instrumented", "shared"],
    build_setting_default = "std"
)
config_setting(name = "std?", flag_values = {":runtime": "std"})
config_setting(name = "pic?", flag_values = {":runtime": "pic"})
config_setting(name = "dbg?", flag_values = {":runtime": "dbg"})
config_setting(name = "instrumented?", flag_values = {":runtime": "instrumented"})
config_setting(name = "shared?", flag_values = {":runtime": "shared"})

filegroup(
    name = "std_exit_cmo",
    srcs = ["std_exit.cmo"]
)
