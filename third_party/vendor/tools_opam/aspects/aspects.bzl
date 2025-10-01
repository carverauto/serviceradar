"""Public aspects for obazl_rules_ocaml LSP.

All public OCaml aspects imported and re-exported in this file.

Definitions outside this file should not be loaded by client code
unless otherwise noted, and may change without notice. """


load("//ocaml/_aspects:ocaml.bzl",
     _print_aspect = "print_aspect",
     _providers = "providers")

print = _print_aspect
providers = _providers

# load("//ocaml/_aspects:ppx_deps.bzl", _print_aspect = "print_aspect")

# print_aspect = _print_aspect
