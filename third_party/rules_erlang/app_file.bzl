load(
    "//private:app_file.bzl",
    _app_file = "app_file",
)

def app_file(
        app_name = "",
        dest = "ebin",
        **kwargs):
    _app_file(
        app_file_tool = Label("//tools/app_file_tool:app_file_tool"),
        app_name = app_name,
        out = "%s/%s.app" % (dest, app_name),
        private_stamp_detect = select({
            Label("//private:private_stamp_detect"): True,
            "//conditions:default": False,
        }),
        **kwargs
    )
