load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load(":app_file.bzl", "app_file")
load("//:util.bzl", "path_join")

def _app_file_test_impl(ctx):
    env = analysistest.begin(ctx)

    target_under_test = analysistest.target_under_test(env)
    asserts.true(
        env,
        target_under_test[DefaultInfo].files.to_list()[0].short_path.endswith(path_join(ctx.label.package, "basic.app")),
    )

    return analysistest.end(env)

app_file_test = analysistest.make(_app_file_test_impl)

def _test_basic():
    app_file(
        name = "app_file_test_subject",
        app_name = "basic",
        app_file_tool = Label("//tools/app_file_tool:app_file_tool"),
        out = "basic.app",
        private_stamp_detect = select({
            Label("//private:private_stamp_detect"): True,
            "//conditions:default": False,
        }),
        tags = ["manual"],
    )

    app_file_test(
        name = "app_file_test",
        target_under_test = ":app_file_test_subject",
    )

def app_file_test_suite(name):
    _test_basic()

    native.test_suite(
        name = name,
        tests = [
            ":app_file_test",
        ],
    )
