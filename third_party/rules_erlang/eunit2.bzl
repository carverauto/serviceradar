load("//private:eunit.bzl", "eunit_test")

def eunit(
        name = "eunit",
        coverdata_to_lcov = Label("@rules_erlang//tools/coverdata_to_lcov:coverdata_to_lcov"),
        **kwargs):
    eunit_test(
        name = name,
        coverdata_to_lcov = coverdata_to_lcov,
        is_windows = select({
            "@bazel_tools//src/conditions:host_windows": True,
            "//conditions:default": False,
        }),
        **kwargs
    )
