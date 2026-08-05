load("@bazel_skylib//rules:copy_file.bzl", "copy_file")
load(":app_file.bzl", "app_file")
load(":erlang_bytecode.bzl", "erlang_bytecode")
load(
    ":erlang_app_info.bzl",
    "erlang_app_info",
    _ErlangAppInfo = "ErlangAppInfo",
)
load(
    ":util.bzl",
    "without",
)

DEFAULT_ERLC_OPTS = [
    "-Werror",
    "+deterministic",
    "+debug_info",
    "+warn_export_vars",
    "+warn_shadow_vars",
    "+warn_obsolete_guard",
]

DEFAULT_TEST_ERLC_OPTS = [
    "+deterministic",
    "+debug_info",
    "+warn_export_vars",
    "+warn_shadow_vars",
    "+warn_obsolete_guard",
    "-DTEST=1",
]

ErlangAppInfo = _ErlangAppInfo

def _erlang_app(
        name = None,
        app_name = "",
        app_version = "",
        app_description = "",
        app_module = "",
        app_registered = [],
        app_env = "",
        app_extra_keys = "",
        extra_apps = [],
        erlc_opts = None,
        extra_hdrs = [],
        extra_srcs = [],
        extra_priv = [],
        extra_license_files = [],
        build_deps = [],
        deps = [],
        runtime_deps = [],
        stamp = None,
        testonly = False,
        # new attrs for gazelle extension
        beam_files = None,
        hdrs = None,
        srcs = None,
        priv = None,
        license_files = None,
        test = False):
    if beam_files != None or hdrs != None or srcs != None or priv != None or license_files != None:
        if erlc_opts != None:
            fail("Cannot set beam_files, hdrs, srcs, priv or license_files AND erlc_opts")
        if len(extra_hdrs) > 0:
            fail("Cannot set beam_files, hdrs, srcs, priv or license_files AND extra_hdrs")
        if len(extra_srcs) > 0:
            fail("Cannot set beam_files, hdrs, srcs, priv or license_files AND extra_srcs")
        if len(extra_priv) > 0:
            fail("Cannot set beam_files, hdrs, srcs, priv or license_files AND extra_priv")
        if len(extra_license_files) > 0:
            fail("Cannot set beam_files, hdrs, srcs, priv or license_files AND extra_license_files")
        if len(build_deps) > 0:
            print("Warning: build_deps are ignored when beam_files is set")
        if len(runtime_deps) > 0:
            print("Warning: deps and runtime_deps are equivalent when beam_files is set, consider just using deps")

    if name == None:
        name = "erlang_app" if not test else "test_erlang_app"

    if stamp == None:
        stamp = -1 if not test else 0

    if erlc_opts == None:
        if not test:
            erlc_opts = select({
                Label("@rules_erlang//:debug_build"): without("+deterministic", DEFAULT_ERLC_OPTS),
                "//conditions:default": DEFAULT_ERLC_OPTS,
            })
        else:
            erlc_opts = select({
                Label("@rules_erlang//:debug_build"): without("+deterministic", DEFAULT_TEST_ERLC_OPTS),
                "//conditions:default": DEFAULT_TEST_ERLC_OPTS,
            })

    if beam_files == None:
        only_srcs = native.glob(
            ["src/**/*.erl"],
            exclude = extra_srcs, allow_empty = True) + extra_srcs
        private_hdrs = native.glob(
            ["src/**/*.hrl"],
            exclude = extra_hdrs, allow_empty = True)
        public_hdrs = native.glob(
            ["include/**/*.hrl"],
            exclude = extra_hdrs, allow_empty = True) + extra_hdrs

        srcs = only_srcs + private_hdrs + public_hdrs
        hdrs = public_hdrs if not test else private_hdrs + public_hdrs

        erlang_bytecode(
            name = "beam_files" if not test else "test_beam_files",
            app_name = app_name,
            hdrs = private_hdrs + public_hdrs,
            srcs = only_srcs,
            erlc_opts = erlc_opts,
            dest = "ebin" if not test else "test",
            deps = build_deps + deps,
            testonly = test or testonly,
        )

        beam_files = [":beam_files" if not test else ":test_beam_files"]

    if len(native.glob(["ebin/{}.app".format(app_name)], allow_empty = True)) == 0:
        if not test:
            app_file(
                name = "app_file",
                app_name = app_name,
                app_version = app_version,
                app_description = app_description,
                app_module = app_module,
                app_registered = app_registered,
                app_env = app_env,
                app_extra_keys = app_extra_keys,
                extra_apps = extra_apps,
                app_src = native.glob(["src/{}.app.src".format(app_name)], allow_empty = True),
                modules = beam_files,
                deps = deps + runtime_deps,
                dest = "ebin",
                stamp = stamp,
                testonly = testonly,
            )
        app = ":app_file"
    else:
        app = "ebin/{}.app".format(app_name)

    if len(native.glob(["ebin/{}.appup".format(app_name)], allow_empty = True)) > 0:
        appup = "ebin/{}.appup".format(app_name)
    elif len(native.glob(["src/{}.appup".format(app_name)], allow_empty = True)) > 0:
        if not test:
            copy_file(
                name = "appup",
                src = "src/{}.appup".format(app_name),
                out = "ebin/{}.appup".format(app_name),
            )
        appup = ":appup"
    else:
        appup = None

    beam_files += [appup] if appup != None else []

    if priv == None:
        priv = native.glob(
            ["priv/**/*"],
            exclude = extra_priv, allow_empty = True) + extra_priv

    if license_files == None:
        license_files = native.glob(
            ["LICENSE*"],
            exclude = extra_license_files, allow_empty = True) + extra_license_files

    erlang_app_info(
        name = name,
        app_name = app_name,
        extra_apps = extra_apps,
        hdrs = hdrs,
        app = app,
        beam = beam_files,
        priv = priv,
        license_files = license_files,
        srcs = srcs,
        deps = deps + runtime_deps,
        visibility = ["//visibility:public"],
        testonly = test or testonly,
    )

def erlang_app(**kwargs):
    _erlang_app(
        test = False,
        **kwargs
    )

def test_erlang_app(**kwargs):
    _erlang_app(
        test = True,
        **kwargs
    )
