load("//private:eunit.bzl", "eunit_test")
load(":erlang_app.bzl", "DEFAULT_TEST_ERLC_OPTS")
load(":erlang_bytecode.bzl", "erlang_bytecode")

def _module_name(p):
    return p.rpartition("/")[-1].replace(".erl", "")

def eunit(
        erlc_opts = DEFAULT_TEST_ERLC_OPTS,
        srcs = None,
        data = [],
        deps = [],
        runtime_deps = [],
        additional_beam = [],
        **kwargs):
    srcs = native.glob(["test/**/*.erl"], exclude = native.glob(["test/*_SUITE.erl"])) if srcs == None else srcs
    erlang_bytecode(
        name = "test_case_beam_files",
        hdrs = native.glob(["include/*.hrl", "src/*.hrl", "test/*.hrl"]),
        srcs = srcs,
        erlc_opts = erlc_opts,
        dest = "test",
        deps = [":test_erlang_app"] + deps,
        testonly = True,
    )

    # eunit_mods is the list of source modules, plus any test module which is
    # not among the eunit_mods with a "_tests" suffix appended
    eunit_ebin_mods = [_module_name(f) for f in native.glob(["src/**/*.erl"])]
    eunit_test_mods = [_module_name(f) for f in srcs]
    eunit_mods = eunit_ebin_mods
    for tm in eunit_test_mods:
        if tm not in [m + "_tests" for m in eunit_ebin_mods]:
            eunit_mods.append(tm)

    eunit_test(
        name = "eunit",
        coverdata_to_lcov = Label("@rules_erlang//tools/coverdata_to_lcov:coverdata_to_lcov"),
        is_windows = select({
            "@bazel_tools//src/conditions:host_windows": True,
            "//conditions:default": False,
        }),
        compiled_suites = [":test_case_beam_files"] + additional_beam,
        eunit_mods = eunit_mods,
        data = native.glob(["test/**/*"], exclude = srcs) + data,
        deps = [":test_erlang_app"] + deps + runtime_deps,
        **kwargs
    )
