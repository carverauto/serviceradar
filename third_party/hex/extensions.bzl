"""The Hex closure, as a single module extension.

This is the whole Hex section of the root MODULE.bazel:

    hex_ext = use_extension("//third_party/hex:extensions.bzl", "hex")
    use_repo(hex_ext, "hexpm")

It used to be ~2,200 lines of `hex_archive()` calls, pasted in by hand from a file the
generator wrote. The data now lives in `hex_packages.bzl` next to the BUILD stubs it
describes, and the same generator run produces both, so the two cannot disagree.

Depend on a package as `@hexpm//:<app>` -- for example `@hexpm//:ecto`. There is exactly one
label per package, because a Bazel repository name is global. If a future closure genuinely
needs two versions of one package side by side, the convention is a version-suffixed pair
(`@hexpm//:plug_crypto_2_1`, `@hexpm//:plug_crypto_2_2`) with each target choosing; until
then the generator consolidates disagreeing locks onto the highest version.

The hub is `@hexpm`, not `@hex`: `@hex` is already the Hex package manager itself, built as
a Mix archive in MODULE.bazel so that Mix can resolve an SCM for dev-only deps.
"""

load("@rules_erlang//bzlmod:hex_packages.bzl", "git_pkg", "hex_packages_extension", "hex_pkg")
load(":hex_packages.bzl", "HEX_PACKAGES")

# Label() rather than a bare string: this is resolved against the repository holding the
# .bzl file that writes it, and the factory it is handed to lives in @rules_erlang.
def _stub(app):
    return Label("//third_party/hex:" + app + ".BUILD")

hex = hex_packages_extension(
    packages = [
        hex_pkg(
            name = app,
            package_name = hex_name,
            version = version,
            sha256 = sha256,
            build_file = _stub(app),
        )
        for (app, hex_name, version, sha256) in HEX_PACKAGES
    ] + [
        # bundlex is the one entry that is not a Hex package -- serviceradar_core_elx pins it
        # from git (membraneframework/bundlex v1.5.4). It ships a Mix compiler that
        # bunch_native and the rest of the Membrane stack invoke as `compile.bundlex`, so
        # without it those packages fail with `The task "compile.bundlex" could not be found`.
        #
        # It belongs in this extension rather than in MODULE.bazel so that it lands in the
        # same repo-mapping namespace as the fetched packages: that is what lets a generated
        # stub inside @hex_bunch_native refer to @hex_bundlex//:erlang_app directly.
        git_pkg(
            name = "bundlex",
            remote = "https://github.com/membraneframework/bundlex.git",
            commit = "8f3b94a8d643c4513d61355be53136cb2ea8fbb4",
            build_file = _stub("bundlex"),
            # Resolve precompiled OS deps from BUNDLEX_LOCAL_PRECOMPILED_DIR before reaching
            # for github.com. Without it `mix deps.compile` downloads ffmpeg and friends
            # inside a build action -- unkeyed, and once per consuming plugin. See the patch
            # header.
            patches = [
                Label("//third_party/patches/bundlex:local_precompiled.patch"),
                # Build natives with the hermetic $CC/$CXX //build:mix_app.bzl exports
                # instead of the executor image's gcc. See the patch header for why this
                # patches the GCC toolchain rather than selecting Toolchain.Custom.
                Label("//third_party/patches/bundlex:hermetic_cc.patch"),
                # Pick the precompiled OS-dep URL from the TARGET triple that
                # //build:mix_app.bzl exports, not from the executor's BEAM. Without it an
                # arm64 build asks for `<dep>_linux_x86.tar.gz`, misses the staged arm
                # archive (matching is by basename) and downloads an x86 library.
                Label("//third_party/patches/bundlex:target_triple.patch"),
            ],
            patch_args = ["-p1"],
        ),
    ],
)
