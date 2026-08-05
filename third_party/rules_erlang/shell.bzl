load(
    "//private:shell.bzl",
    _shell = "shell",
)

def shell(**kwargs):
    _shell(
        is_windows = select({
            "@bazel_tools//src/conditions:host_windows": True,
            "//conditions:default": False,
        }),
        **kwargs
    )
