load(
    "//private:dialyze.bzl",
    "dialyze_test",
)
load(
    "//private:plt.bzl",
    _plt = "plt",
)

DEFAULT_PLT_APPS = ["erts", "kernel", "stdlib"]

DIALYZE_TAG = "dialyze"

def plt(
        for_target = None,
        apps = None,
        testonly = True,
        **kwargs):
    if for_target == None and apps == None:
        apps = DEFAULT_PLT_APPS
    _plt(
        for_target = for_target,
        apps = apps,
        testonly = testonly,
        **kwargs
    )

def dialyze(
        name = "dialyze",
        target = ":erlang_app",
        tags = [],
        **kwargs):
    dialyze_test(
        name = name,
        target = target,
        is_windows = select({
            "@bazel_tools//src/conditions:host_windows": True,
            "//conditions:default": False,
        }),
        tags = tags + [DIALYZE_TAG],
        **kwargs
    )
