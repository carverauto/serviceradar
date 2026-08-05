load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":util.bzl", "path_join")

def _path_join_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(
        env,
        expected = "path/to/myfile.erl",
        actual = path_join("path", "", "to", "myfile.erl"),
    )

    return unittest.end(env)

path_join_test = unittest.make(_path_join_test_impl)

def util_test_suite(name):
    unittest.suite(
        name,
        path_join_test,
    )
