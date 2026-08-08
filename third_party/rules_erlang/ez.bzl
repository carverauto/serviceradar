load(
    "//private:ez.bzl",
    _ez = "ez",
)

def ez(**kwargs):
    _ez(
        private_stamp_detect = select({
            Label("//private:private_stamp_detect"): True,
            "//conditions:default": False,
        }),
        **kwargs
    )
