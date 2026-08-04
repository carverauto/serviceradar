# Erlang Gazelle plugin

This directory contains a plugin for [Gazelle](https://github.com/bazelbuild/bazel-gazelle) that generates and updates BUILD files for erlang code.

This plugin is currently based on the [rules_python implementation](https://github.com/bazelbuild/rules_python/tree/main/gazelle).

## To use

Create a WORKSPACE file with:

```starlark
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

http_archive(
    name = "io_bazel_rules_go",
    sha256 = "099a9fb96a376ccbbb7d291ed4ecbdfd42f6bc822ab77ae6f1b5cb9e914e94fa",
    urls = [
        "https://mirror.bazel.build/github.com/bazelbuild/rules_go/releases/download/v0.35.0/rules_go-v0.35.0.zip",
        "https://github.com/bazelbuild/rules_go/releases/download/v0.35.0/rules_go-v0.35.0.zip",
    ],
)

http_archive(
    name = "bazel_gazelle",
    sha256 = "efbbba6ac1a4fd342d5122cbdfdb82aeb2cf2862e35022c752eaddffada7c3f3",
    urls = [
        "https://mirror.bazel.build/github.com/bazelbuild/bazel-gazelle/releases/download/v0.27.0/bazel-gazelle-v0.27.0.tar.gz",
        "https://github.com/bazelbuild/bazel-gazelle/releases/download/v0.27.0/bazel-gazelle-v0.27.0.tar.gz",
    ],
)


load("@io_bazel_rules_go//go:deps.bzl", "go_register_toolchains", "go_rules_dependencies")
load("@bazel_gazelle//:deps.bzl", "gazelle_dependencies", "go_repository")

############################################################
# Define your own dependencies here using go_repository.
# Else, dependencies declared by rules_go/gazelle will be used.
# The first declaration of an external repository "wins".
############################################################

go_rules_dependencies()

go_register_toolchains(go_version = "1.18.3")

gazelle_dependencies()

git_repository(
    name = "rules_erlang",
    branch = "experimental-gazelle-extension",
    remote = "https://github.com/rabbitmq/rules_erlang.git",
)

load(
    "@rules_erlang//gazelle:deps.bzl",
    _erlang_gazelle_deps = "gazelle_deps",
)

_erlang_gazelle_deps()

load(
    "@rules_erlang//:rules_erlang.bzl",
    "erlang_config",
    "rules_erlang_dependencies",
)

erlang_config()

rules_erlang_dependencies()

load("@erlang_config//:defaults.bzl", "register_defaults")

register_defaults()
```

And a `BUILD` file with:

```starlark
load("@bazel_gazelle//:def.bzl", "gazelle")
load("@rules_erlang//gazelle:def.bzl", "GAZELLE_ERLANG_RUNTIME_DEPS")

gazelle(
    name = "gazelle",
    data = GAZELLE_ERLANG_RUNTIME_DEPS,
    gazelle = "@rules_erlang//gazelle:gazelle_erlang_binary",
)
```

Then run `bazel run //:gazelle`

## Directives

- `erlang_resolve`

  Example: `# gazelle:erlang_resolve rabbit_common @rabbitmq-server//deps/rabbit_common:erlang_app`

  Purpose: Provides explicit resolution from an erlang application name to it's label

- `erlang_module_source_lib`

  Example: `# gazelle:erlang_module_source_lib Elixir.RabbitMQ.CLI.CommandBehaviour:rabbitmq_cli`

  Purpose: Indicates which erlang application contains a given module, irrespective of `moduleindex.yaml`

- `erlang_exclude_when_rule_of_kind_exists`

  Purpose: Tells the erlang extension for gazelle to skip rule generation for a given directory, if a BUILD file already exists and contains a rule of this type

- `erlang_generate_beam_files_macro`

  Example: `# gazelle:erlang_generate_beam_files_macro`

  Purpose: Tells the erlang extension to generate `app.bzl` and define all of the rules for compiling beam files within it. This allows for a much more compact BUILD file

- `erlang_generate_fewer_bytecode_rules`

  Purpose: Tells the erlang extension to generate rules that compile byte code in up to 3 phases (parse transforms, behaviours, the rest) instead of generating a rule per beam file (the default). This can provide a speed boost for some projects, such as rabbitmq-server, which is an umbrella project with many sources and applications.

- `erlang_always_generate_test_beam_files`

  Purpose: Tells the erlang extention to generate the rules that compile source for test, even if the application contains no test suites

- `erlang_skip_rules`

  Example: `# gazelle:erlang_skip_rules assert_suites2,xref,plt,dialyze
`

  Purpose: Tells the erlang extension not to generate rules of these types

- `erlang_apps_dirs`

  Example: `# gazelle:erlang_apps_dirs deps`

  Purpose: Tells the erlang extension too look in additional directories within the project in addition to `apps` for local applications. Only useful for umbrella repos.

- `erlang_app_testonly`

  Purpose: Sets `testonly = True` on the rules generated. Useful for marking a test dependency as something that should not be shipped.

- `erlang_app_dep`

  Purpose: An erlang application name to add as a depencency, in addition to the detected deps

- `erlang_app_dep_ignore`

  Purpose: Ignores a detected dependency entirely, both for compilation and runtime

- `erlang_app_dep_exclude`

  Example: `# gazelle:erlang_app_dep_exclude rabbitmq_cli`

  Purpose: Excludes a detected dependency from the generated `.app` file for an app, useful for optional dependencies

- `erlang_app_path_ignore`

  Purpose: Exclude files matching the pattern from an `erlang_app` rule and its sources

- `erlang_app_extra_app`

  Purpose: Inject an additional application into the `.app` file, under the `applications` key

- `erlang_no_tests`

  Purpose: Don't generate rules associated with tests. Useful for dependencies

- `erlang_erlc_opt`

  Example: `# gazelle:erlang_erlc_opt -DBUILD_WITHOUT_QUIC`

  Purpose: Adds additional values to the `erlc_opts` rule. Useful as it applies when parsing sources to determine dependencies
