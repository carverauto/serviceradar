load(
    "//private:ex_unit_test.bzl",
    _ex_unit_test = "ex_unit_test",
)

def ex_unit_test(**kwargs):
    _ex_unit_test(
        is_windows = select({
            "@bazel_tools//src/conditions:host_windows": True,
            "//conditions:default": False,
        }),
        **kwargs
    )
