load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

_TestSources = provider(fields = ["files"])

def _test_sources_impl(_target, ctx):
    return [_TestSources(files = depset(transitive = [src[DefaultInfo].files for src in ctx.rule.attr.srcs]))]

_test_sources = aspect(implementation = _test_sources_impl)

def _go_test_inventory_impl(ctx):
    env = unittest.begin(ctx)
    expected = sorted([src.short_path for src in ctx.files.srcs])
    actual = sorted([src.short_path for src in ctx.attr.target[_TestSources].files.to_list() if src.basename.endswith("_test.go")])
    asserts.true(env, bool(expected), "test inventory must not be empty")
    asserts.equals(env, expected, actual)
    return unittest.end(env)

go_test_inventory_test = unittest.make(
    _go_test_inventory_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = True),
        "target": attr.label(mandatory = True, aspects = [_test_sources]),
    },
)
