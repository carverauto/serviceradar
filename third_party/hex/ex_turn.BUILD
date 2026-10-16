load("@rules_elixir//:mix_app.bzl", "mix_app")
load("@serviceradar//build:hex_compile_env.bzl", "HEX_COMPILE_ENV_CONFIG")

package(default_visibility = ["//visibility:public"])

# Hand-written: ex_turn is pinned from git rather than Hex (see
# //third_party/hex:extensions.bzl), so //third_party/hex:stubs does not emit it and must not
# prune it. Deps mirror its own mix.exs. Compiled with Mix, like the generated stubs, so
# mix.exs and Mix.Project introspection work.
filegroup(
    name = "sources",
    srcs = glob(
        ["**/*"],
        allow_empty = True,
    ),
)

mix_app(
    name = "erlang_app",
    app_name = "ex_turn",
    srcs = [":sources"],
    hdrs = glob(
        ["include/**/*.hrl"],
        allow_empty = True,
    ),
    extra_config = HEX_COMPILE_ENV_CONFIG,
    deps = [
        "@hex_ex_stun//:erlang_app",
        "@rules_elixir//elixir",
    ],
)
