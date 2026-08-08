load(
    "//private:shell.bzl",
    _shell = "shell",
)

def shell(**kwargs):
    _shell(
        is_windows = select({
            "@platforms//os:windows": True,
            "//conditions:default": False,
        }),
        **kwargs
    )
