# generated file - DO NOT EDIT

load("@rules_ocaml//build:rules.bzl", "ocaml_import")
# load("@tools_opam//build:rules.bzl", "opam_import")

package(default_visibility = ["//visibility:public"])

ocaml_import(
    name       = "common",
    doc        = """Common compiler routines""",
    sigs       = glob(["*.cmi"], allow_empty=True),
    archive    =  select({
        "@rules_ocaml//platform/executor:vm" : "ocamlcommon.cma",
        "@rules_ocaml//platform/executor:sys": "ocamlcommon.cmxa",
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
    all        = glob(["*"], allow_empty=True),
)

ocaml_import(
    name       = "bytecomp",
    doc        = """Common compiler routines""",
    sigs       = glob(["*.cmi"], allow_empty=True),
    archive    =  select({
        "@rules_ocaml//platform/executor:vm" : "ocamlbytecomp.cma",
        "@rules_ocaml//platform/executor:sys": "ocamlbytecomp.cmxa",
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
    cmts        = glob(["*.cmt"], allow_empty=True),
    cmtis       = glob(["*.cmti"], allow_empty=True),
    srcs       = glob(["*.ml", "*.mli"], allow_empty=True),
    all        = glob(["*"], allow_empty=True),
)

ocaml_import(
    name       = "optcomp",
    doc        = """optcomp compiler routines""",
    sigs       = glob(["*.cmi"], allow_empty=True),
    archive    =  select({
        "@rules_ocaml//platform/executor:vm" : "ocamloptcomp.cma",
        "@rules_ocaml//platform/executor:sys": "ocamloptcomp.cmxa",
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
    cmts        = glob(["*.cmt"], allow_empty=True),
    cmtis       = glob(["*.cmti"], allow_empty=True),
    srcs       = glob(["*.ml", "*.mli"], allow_empty=True),
    all        = glob(["*"], allow_empty=True),
)

ocaml_import(
    name = "toplevel",
    doc = """Toplevel interactions""",
    sigs       = glob(["*.cmi"], allow_empty=True),
    archive    =  "ocamltoplevel.cma",
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
    cmts        = glob(["*.cmt"], allow_empty=True),
    cmtis       = glob(["*.cmti"], allow_empty=True),
    srcs = glob(["*.ml", "*.mli"], allow_empty=True),
    all = glob(["*.cmx", "*.cmi"], allow_empty=True),
    deps = [":bytecomp"],
)

ocaml_import(
    name = "native-toplevel",
    doc = """Toplevel interactions""",
    sigs       = glob(["*.cmi"], allow_empty=True),
    archive    =  "ocamltoplevel.cmxa",
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
    cmts        = glob(["*.cmt"], allow_empty=True),
    cmtis       = glob(["*.cmti"], allow_empty=True),
    srcs = glob(["*.ml", "*.mli"], allow_empty=True),
    all = glob(["*.cmx", "*.cmi"], allow_empty=True),
    deps = [":optcomp", "@opam.ocamlsdk//lib/dynlink"],
)

# exports_files([
#     "ocamlcommon.cma",
#     "ocamlcommon.cmxa",
#     "ocamlcommon.a",

#     "ocamlbytecomp.cma",
#     "ocamlbytecomp.cmxa",
#     "ocamlbytecomp.a",

#     "ocamloptcomp.cma",
#     "ocamloptcomp.cmxa",
#     "ocamloptcomp.a",

#     "ocamlmiddleend.cma",
#     "ocamlmiddleend.cmxa",
#     "ocamlmiddleend.a",

#     "ocamltoplevel.cma",
#     "ocamltoplevel.cmxa",
#     "ocamltoplevel.a",
# ])

# filegroup(
#     name = "all",
#     srcs = glob([
#         "*.cmx", "*.o", "*.cmo",
#         "*.cmt", "*.cmti",
#         "*.mli", "*.cmi",
#     ]),
# )
