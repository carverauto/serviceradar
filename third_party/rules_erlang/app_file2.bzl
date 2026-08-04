load(
    "//private:app_file.bzl",
    _app_file = "app_file",
)

def app_file(**kwargs):
    _app_file(
        app_file_tool = Label("//tools/app_file_tool:app_file_tool"),
        private_stamp_detect = select({
            Label("//private:private_stamp_detect"): True,
            "//conditions:default": False,
        }),
        **kwargs
    )
