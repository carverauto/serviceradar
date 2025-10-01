"""Local-only wrappers for OCaml rules."""

load(
    "@rules_ocaml//build:rules.bzl",
    _ocaml_binary = "ocaml_binary",
    _ocaml_library = "ocaml_library",
    _ocaml_module = "ocaml_module",
    _ocaml_test = "ocaml_test",
)

# The OCaml toolchain is now available on the remote executor image, so we no
# longer need to force these targets to run locally or mark them incompatible
# when `--config=remote` is enabled. The wrappers remain in place to keep the
# call sites stable should we need to reintroduce overrides later.
def _apply_local_overrides(kwargs):
    if "target_compatible_with" in kwargs:
        fail("ocaml_local_rules wrappers do not support overriding target_compatible_with")
    return dict(kwargs)

def ocaml_module(**kwargs):
    _ocaml_module(**_apply_local_overrides(kwargs))

def ocaml_library(**kwargs):
    _ocaml_library(**_apply_local_overrides(kwargs))

def ocaml_binary(**kwargs):
    _ocaml_binary(**_apply_local_overrides(kwargs))

def ocaml_test(**kwargs):
    _ocaml_test(**_apply_local_overrides(kwargs))
