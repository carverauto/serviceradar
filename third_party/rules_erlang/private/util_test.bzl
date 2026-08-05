load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":util.bzl", "additional_file_dest_relative_path")

def _additional_file_dest_relative_path_test_impl(ctx):
    env = unittest.begin(ctx)

    local_file = ctx.actions.declare_file("additional_file_dest_relative_path.testfile")
    ctx.actions.write(local_file, "")

    asserts.equals(
        env,
        expected = "additional_file_dest_relative_path.testfile",
        actual = additional_file_dest_relative_path(Label("//private:private_stamp_detect"), local_file),
    )

    asserts.equals(
        env,
        expected = "private/additional_file_dest_relative_path.testfile",
        actual = additional_file_dest_relative_path(Label("//:debug_build"), local_file),
    )

    thoas_app_file = None
    for f in ctx.files.thoas:
        if f.basename == "thoas.app":
            thoas_app_file = f
            break

    asserts.equals(
        env,
        expected = "ebin/thoas.app",
        actual = additional_file_dest_relative_path(ctx.attr.thoas.label, thoas_app_file),
    )

    return unittest.end(env)

additional_file_dest_relative_path_test = unittest.make(
    _additional_file_dest_relative_path_test_impl,
    attrs = {
        "thoas": attr.label(default = Label("@thoas_rules_erlang//:erlang_app")),
    },
)

def util_test_suite(name):
    unittest.suite(
        name,
        additional_file_dest_relative_path_test,
    )
