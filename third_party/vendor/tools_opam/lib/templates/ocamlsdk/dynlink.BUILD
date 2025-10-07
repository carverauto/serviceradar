# generated file - DO NOT EDIT

load("@rules_ocaml//build:rules.bzl", "ocaml_import")

package(default_visibility = ["//visibility:public"])

alias(name = "lib", actual = ":dynlink")

ocaml_import(
    name       = "dynlink",
    version    = "[distributed with OCaml]",
    sigs       = glob(["*.cmi"], allow_empty=True),
    archive    =  select({
        "@rules_ocaml//platform/executor:vm" : "dynlink.cma",
        "@rules_ocaml//platform/executor:sys": "dynlink.cmxa",
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
    all        = glob(["dyn*.*"], allow_empty=True),
);

