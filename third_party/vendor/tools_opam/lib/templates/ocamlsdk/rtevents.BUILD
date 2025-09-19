# generated file - DO NOT EDIT

load("@rules_ocaml//build:rules.bzl", "ocaml_import")

package(default_visibility = ["//visibility:public"])

alias(name = "lib", actual = ":runtime_events")

ocaml_import(
    name       = "runtime_events",
    version    = """[distributed with Ocaml]""",
    doc        = """Runtime events""",
    sigs       = glob(["*.cmi"], allow_empty=True),
    archive    =  select({
        "@rules_ocaml//platform/executor:vm" : "runtime_events.cma",
        "@rules_ocaml//platform/executor:sys": "runtime_events.cmxa",
    }, no_match_error="Bad platform"),
    afiles   = select({
        "@rules_ocaml//platform/executor:vm" : [],
        "@rules_ocaml//platform/executor:sys": glob(["*.a"],
                                                   allow_empty=True,
                                                   exclude=["*_stubs.a"])
    }, no_match_error="Bad platform"),
    astructs = select({
        "@rules_ocaml//platform/executor:vm" : [],
        "@rules_ocaml//platform/executor:sys": glob(["*.cmx"], allow_empty=True)
    }, no_match_error="Bad platform"),
    ofiles   = select({
        "@rules_ocaml//platform/executor:vm" : [],
        "@rules_ocaml//platform/executor:sys": glob(["*.o"], allow_empty=True)
    }, no_match_error="Bad platform"),
    cmts       = glob(["*.cmt"], allow_empty=True),
    cmtis      = glob(["*.cmti"], allow_empty=True),
    srcs       = glob(["*.ml", "*.mli"], allow_empty=True),
    all        = glob(["runtime_events.*"], allow_empty=True),
)

ocaml_import(
    name       = "plugin",
    plugin     =  select({
        "@rules_ocaml//platform/executor:vm": "runtime_events.cma",
        "//conditions:default":         "runtime_events.cmxs",
    }),
    # cmxs       = "runtime_events.cmxs",
    # cma        = "runtime_events.cma",
)
