# generated file - DO NOT EDIT

load("@rules_ocaml//build:rules.bzl", "ocaml_import")

ocaml_import(
    name       = "bigarray",
    version    = "[distributed with OCaml]",
    sigs       = glob(["*.cmi"]),
    archive    =  select({
        "@ocaml//platform/executor:vm": "bigarray.cma",
        "//conditions:default":         "bigarray.cmxa",
    }),
    afiles     = glob(["*.a"]),
    astructs   = glob(["*.cmx"]),
    ofiles     = glob(["*.o"]),
    cmts       = glob(["*.cmt"]),
    cmtis      = glob(["*.cmti"]),
    srcs       = glob(["*.ml", "*.mli"]),
    all        = glob(["bigarray.*"]),

    deps       = ["@ocaml//unix"],
    visibility = ["//visibility:public"],
)

ocaml_import(
    name       = "plugin",
    version    = "[distributed with OCaml]",
    plugin     =  select({
        "@ocaml//platform/executor:vm": "bigarray.cma",
        "//conditions:default":         "bigarray.cmxs",
    }),
    # cmxs       = "bigarray.cmxs",
    # cma        = "bigarray.cma",
    deps       = ["@ocaml//unix"],
    visibility = ["//visibility:public"],
);
