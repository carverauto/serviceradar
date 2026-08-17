load("@rules_elixir//:mix_app.bzl", "mix_app")

package(default_visibility = ["//visibility:public"])

# Hand-written: bundlex is pinned from git rather than Hex, so //third_party/hex:gen
# does not emit it -- and must not prune it. Deps mirror its own mix.exs, minus the
# :dev-only ones. The repository itself is declared as a git_pkg in
# //third_party/hex:extensions.bzl.
filegroup(
    name = "sources",
    srcs = glob(
        ["**/*"],
        allow_empty = True,
    ),
)

mix_app(
    name = "erlang_app",
    srcs = [":sources"],
    app_name = "bundlex",
    deps = [
        "@hex_bunch//:erlang_app",
        "@hex_qex//:erlang_app",
        "@hex_req//:erlang_app",
        "@hex_zarex//:erlang_app",
        "@rules_elixir//elixir",
        # elixir_uuid is overridden repo-wide by the first-party copy; see @path_deps in
        # scripts/gen_hex_bazel.exs.
        "@serviceradar//third_party/hex_vendored/elixir_uuid:erlang_app",
    ],
)
