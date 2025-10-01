# generated file - DO NOT EDIT

package(default_visibility = ["//visibility:public"])

genrule(
    name = "config",
    tools = ["@opam.ocamlsdk//bin:ocamlc"],
    srcs  = [],
    outs  = ["ocamlconfig.txt"],
    cmd   = "$(execpath @opam.ocamlsdk//bin:ocamlc) -config | tee \"$@\"",
)
