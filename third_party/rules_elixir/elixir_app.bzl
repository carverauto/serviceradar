load("@rules_erlang//:app_file2.bzl", "app_file")
load("@rules_erlang//:erlang_app_info.bzl", "erlang_app_info")
load("//private:elixir_bytecode.bzl", "elixir_bytecode")
load("//private:elixir_ebin_dir.bzl", "elixir_ebin_dir")
load("//private:erlang_app_filter_module_conflicts.bzl", "erlang_app_filter_module_conflicts")

def elixir_app(
        app_name = None,
        extra_apps = [],
        srcs = None,
        data = [],
        elixirc_opts = [],
        ez_deps = [],
        deps = [],
        **kwargs):
    """compiles elixir sources in a manner compatible with @rules_erlang

    Args:
      app_name: Name of the application
      extra_apps: additional apps (elixir is always included) injected into
          the .app file
      srcs: Sources. Defaults to "lib/**/*.ex"
      elixirc_opts: elixirc options
      ez_deps: Dependencies that are .ez files
      deps: ErlangAppInfo labels
      **kwargs: Additional args passed to the underlying app_file rule, such
          as app_description

    Returns:
      Nothing
    """
    if srcs == None:
        srcs = native.glob([
            "lib/**/*.ex",
        ])

    elixir_bytecode(
        name = "beam_files",
        srcs = srcs,
        data = data,
        dest = "beam_files",
        elixirc_opts = elixirc_opts,
        ez_deps = ez_deps,
        deps = deps,
    )

    app_file(
        name = "app_file",
        out = "%s.app" % app_name,
        app_name = app_name,
        extra_apps = ["elixir"] + extra_apps,
        modules = [":beam_files"],
        **kwargs
    )

    elixir_ebin_dir(
        name = "ebin",
        beam_files_dir = ":beam_files",
        app_file = ":app_file",
        dest = "ebin",
    )

    erlang_app_filter_module_conflicts(
        name = "elixir_without_app_overlap",
        dest = "unconsolidated",
        src = Label("@rules_elixir//elixir:elixir"),
        without = [":ebin"],
    )

    erlang_app_info(
        name = "erlang_app",
        srcs = srcs,
        hdrs = [],
        app_name = app_name,
        beam = [":ebin"],
        extra_apps = extra_apps,
        # allow_empty: plenty of Hex packages ship no LICENSE file (ash among them), and
        # with --incompatible_disallow_empty_glob on -- the default since Bazel 7 -- an
        # empty glob is a hard error, so those packages could not be built at all.
        license_files = native.glob(["LICENSE*"], allow_empty = True),
        priv = [],
        visibility = ["//visibility:public"],
        deps = [
            ":elixir_without_app_overlap",
        ] + deps,
    )
