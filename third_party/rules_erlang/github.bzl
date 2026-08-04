load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load(":erlang_app.bzl", "DEFAULT_ERLC_OPTS")

def github_erlang_app(
        name = None,
        org = None,
        repo = None,
        version = "master",
        ref = "refs/heads/master",
        extra_apps = [],
        deps = [],
        runtime_deps = [],
        erlc_opts = DEFAULT_ERLC_OPTS,
        strip_prefix = None,
        **kwargs):
    if not ("build_file" in kwargs.keys() or "build_file_content" in kwargs.keys()):
        kwargs.update(build_file_content = _BUILD_FILE_TEMPLATE.format(
            app_name = name,
            version = version,
            extra_apps = extra_apps,
            deps = deps,
            runtime_deps = runtime_deps,
            erlc_opts = erlc_opts,
            stamp = 0,
        ))

    repo = name if repo == None else repo
    strip_prefix = "{}-{}".format(repo, version) if strip_prefix == None else strip_prefix

    http_archive(
        name = name,
        urls = ["https://github.com/{}/{}/archive/{}.zip".format(org, repo, ref)],
        strip_prefix = strip_prefix,
        **kwargs
    )

_BUILD_FILE_TEMPLATE = """load("@rules_erlang//:erlang_app.bzl", "erlang_app")

erlang_app(
    app_name = "{app_name}",
    app_version = "{version}",
    extra_apps = {extra_apps},
    deps = {deps},
    runtime_deps = {runtime_deps},
    erlc_opts = {erlc_opts},
)
"""
