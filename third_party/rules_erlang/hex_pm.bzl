load(":erlang_app.bzl", "DEFAULT_ERLC_OPTS")
load(":hex_archive.bzl", "hex_archive")

def hex_pm_erlang_app(
        name = None,
        version = None,
        app_name = None,
        erlc_opts = DEFAULT_ERLC_OPTS,
        deps = [],
        runtime_deps = [],
        **kwargs):
    if not ("build_file" in kwargs.keys() or "build_file_content" in kwargs.keys()):
        if app_name == None:
            app_name = name
        kwargs.update(build_file_content = _BUILD_FILE_TEMPLATE.format(
            app_name = app_name,
            version = version,
            erlc_opts = erlc_opts,
            deps = deps,
            runtime_deps = runtime_deps,
        ))

    hex_archive(
        name = name,
        version = version,
        **kwargs
    )

_BUILD_FILE_TEMPLATE = """load("@rules_erlang//:erlang_app.bzl", "erlang_app")

erlang_app(
    app_name = "{app_name}",
    app_version = "{version}",
    erlc_opts = {erlc_opts},
    deps = {deps},
    runtime_deps = {runtime_deps},
    stamp = 0,
)
"""
