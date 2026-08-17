"""mix_app with this repository's payloads attached.

The rule is @rules_elixir//:mix_app.bzl. Its payload attributes have no defaults, because a
ruleset cannot name a consumer's repositories -- when they did have defaults, they were bare
`//...` labels that resolved against whichever module happened to hold the rule.

Everything Mix needs here is the same for every target, so it is injected once rather than
repeated at ~15 call sites. Callers can still override any of it by passing the attribute.

The generated Hex stubs cannot use this wrapper: they are TEXT emitted by the generator, so
they carry the same list literally in //third_party/hex:BUILD.bazel. Keep the two in step.
"""

load("@rules_elixir//:mix_app.bzl", _mix_app = "mix_app")

MIX_PAYLOADS = {
    # The Hex package manager itself, as a Mix archive. Not used to fetch anything -- every
    # dependency is already a Bazel repository and mix runs with --no-deps-check -- but Mix
    # refuses to resolve a project without it, aborting with "Could not find an SCM for
    # dependency" even for a dev-only dep nothing would compile.
    "archives": ["@hex//:archive"],
    # Hermetic LLVM's C++ static runtime. A NIF that compiles C++ and links no C++ runtime
    # builds clean and then fails dlopen on its first unresolved symbol.
    "cxx_static_runtime": "@llvm//runtimes/cxxstdlib:static_runtime_lib",
    # Label(), not a bare "//..." string: a label string in a .bzl is resolved by the package
    # that CALLS the macro, and the generated Hex stubs call it from inside @hex_<pkg>.
    "elixir_make_nifs": [Label("//third_party/precompiled_nifs:elixir_make_nifs")],
    "elixir_make_nifs_target": [Label("//third_party/precompiled_nifs:elixir_make_nifs_target")],
    "openssl_sysroot": Label("//third_party/openssl:sysroot_tar"),
    "precompiled_nifs": [Label("//third_party/precompiled_nifs:precompiled_nifs")],
    "precompiled_os_deps": [Label("//third_party/membrane:precompiled_os_deps")],
}

def mix_app(**kwargs):
    for attr, value in MIX_PAYLOADS.items():
        if attr not in kwargs:
            kwargs[attr] = value
    return _mix_app(**kwargs)
