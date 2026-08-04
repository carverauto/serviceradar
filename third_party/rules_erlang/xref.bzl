load("//private:xref.bzl", "xref_test")

XREF_TAG = "xref"

def xref(
        name = "xref",
        target = ":erlang_app",
        tags = [],
        **kwargs):
    xref_test(
        xrefr = Label("@rules_erlang//tools/xref_runner:xrefr"),
        name = name,
        target = target,
        is_windows = select({
            "@bazel_tools//src/conditions:host_windows": True,
            "//conditions:default": False,
        }),
        tags = tags + [XREF_TAG],
        **kwargs
    )
