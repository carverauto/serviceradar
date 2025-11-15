def _repo_alias_impl(ctx):
    actual = ctx.attr.actual
    if not actual.startswith("@"):
        fail("repo_alias 'actual' must be a repository label (e.g. '@repo'), got {}".format(actual))

    build_path = ctx.path(Label(actual + "//:BUILD.bazel"))
    ctx.symlink(build_path.dirname, ".")

repo_alias = repository_rule(
    implementation = _repo_alias_impl,
    attrs = {
        "actual": attr.string(mandatory = True),
    },
    doc = "Simple repository alias wrapper for Bzlmod.",
)
