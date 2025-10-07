"""Public definitions for OPAM rules.

All public OPAM rules imported and re-exported in this file.

Definitions outside this file are private unless otherwise noted, and
may change without notice.
"""

load("//build/_rules:opam_build.bzl",
     _opam_build = "opam_build")
# load("//build/_rules:opam_proxy.bzl", _opam_proxy = "opam_proxy")

opam_build    = _opam_build
# opam_proxy = _opam_proxy
