"""Local-only wrappers for OCaml rules."""

load(
    "@rules_ocaml//build:rules.bzl",
    _ocaml_binary = "ocaml_binary",
    _ocaml_library = "ocaml_library",
    _ocaml_module = "ocaml_module",
    _ocaml_test = "ocaml_test",
)

# OCaml toolchains bundled in the repo only provide macOS binaries. Force these
# targets to execute locally so remote Linux executors never try to run the
# incompatible toolchain binaries, and mark them incompatible with the remote
# executor configuration so Bazel skips them entirely when `--config=remote` is
# active.
LOCAL_ONLY_TAGS = ["no-remote-exec"]
_REMOTE_INCOMPATIBLE = select({
    "//ocaml/srql:remote_executor": ["@platforms//:incompatible"],
    "//conditions:default": [],
})

def _apply_local_overrides(kwargs):
    new_kwargs = dict(kwargs)
    existing_tags = new_kwargs.get("tags", [])
    combined_tags = []
    for tag in existing_tags + LOCAL_ONLY_TAGS:
        if tag not in combined_tags:
            combined_tags.append(tag)
    new_kwargs["tags"] = combined_tags

    if "target_compatible_with" in new_kwargs:
        fail("ocaml_local_rules wrappers do not support overriding target_compatible_with")
    new_kwargs["target_compatible_with"] = _REMOTE_INCOMPATIBLE
    return new_kwargs

def ocaml_module(**kwargs):
    _ocaml_module(**_apply_local_overrides(kwargs))

def ocaml_library(**kwargs):
    _ocaml_library(**_apply_local_overrides(kwargs))

def ocaml_binary(**kwargs):
    _ocaml_binary(**_apply_local_overrides(kwargs))

def ocaml_test(**kwargs):
    _ocaml_test(**_apply_local_overrides(kwargs))
