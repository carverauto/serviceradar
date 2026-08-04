load("@bazel_gazelle//:deps.bzl", "gazelle_dependencies")
load("@bazel_skylib//:workspace.bzl", "bazel_skylib_workspace")
load("@io_bazel_rules_go//go:deps.bzl", "go_register_toolchains", "go_rules_dependencies")
load("//gazelle:deps.bzl", "gazelle_deps")

def rules_erlang_internal_setup(
        go_repository_default_config = "//:WORKSPACE.bazel"):
    bazel_skylib_workspace()

    go_rules_dependencies()
    go_register_toolchains(version = "1.19.3")

    gazelle_dependencies(
        go_repository_default_config = go_repository_default_config,
    )

    # gazelle:repository_macro gazelle/deps.bzl%gazelle_deps
    gazelle_deps()
