"""Host TinyGo repository rule for first-party Wasm plugin builds."""

_TINYGO_SHA256 = {
    "darwin_amd64": "36c9423a63f9548d142908b06c67e198d878a0fed076b8ec5dbf8a3350a73eb4",
    "darwin_arm64": "a20841a616de3b3403e52e3789cb60c147ab52b3fe6c33b31fdffba0164ae031",
    "linux_amd64": "064fc0c07f4d71f7369b168c337caa88ef32a6b00b16449cea44790ccadfc2b4",
    "linux_arm64": "4720693b333826569d5c1ed746a735c4d1983719c95af5bdd4d9dfeaa755e933",
}

# TinyGo's Linux release tarballs ship wasm-opt in tinygo/bin, right next to the tinygo binary,
# where TinyGo finds it with no help. The macOS tarballs ship tinygo alone. So `bazel build
# //go/...` -- which reaches these genrules through //go/pkg/agent:plugin_runtime_action_test's
# data deps -- succeeded on Linux CI and died on any Mac with "could not find wasm-opt, set the
# WASMOPT environment variable to override". The build was never hermetic; it worked on Linux
# by accident of upstream packaging, and on a Mac only if the developer happened to have run
# `brew install binaryen`.
#
# Binaryen is fetched below for the two darwin platforms and extracted INTO darwin_*/tinygo, so
# the macOS tree ends up shaped like the Linux one: bin/wasm-opt beside bin/tinygo, and
# lib/libbinaryen.dylib where wasm-opt's @rpath (@executable_path/../lib) resolves it. TinyGo
# then discovers it exactly as it does on Linux, which is why neither defs.bzl nor
# build_wasm_binary.sh needs to know this happened.
#
# version_116 is not arbitrary. TinyGo v0.40.1 pins lib/binaryen at commit
# 11dba9b1c2ad988500b329727f39f4d8786918c5, and that commit IS the version_116 tag, so a Mac
# optimises with the same binaryen revision CI's bundled copy was built from. When the TinyGo
# version above moves, re-check the submodule -- a mismatched optimiser would still produce
# valid wasm, just not the same bytes as the artifact that ships:
#
#   curl -sS https://api.github.com/repos/tinygo-org/tinygo/contents/lib/binaryen?ref=v<VERSION>
_BINARYEN_VERSION = "116"
_BINARYEN_ASSET = {
    "darwin_amd64": "x86_64-macos",
    "darwin_arm64": "arm64-macos",
}
_BINARYEN_SHA256 = {
    "darwin_amd64": "266f63d3d8d9e17d5e532b8fc6c5340f92b3fea2020a634957a6dd938294ba56",
    "darwin_arm64": "d8c978aec366629eae6fefbcedaf5093b829e4c5ab0e2990973b6e337c544867",
}

_GO_VERSION = "1.25.5"
_GO_SHA256 = {
    "darwin_amd64": "b69d51bce599e5381a94ce15263ae644ec84667a5ce23d58dc2e63e2c12a9f56",
    "darwin_arm64": "bed8ebe824e3d3b27e8471d1307f803fc6ab8e1d0eb7a4ae196979bd9b801dd3",
    "linux_amd64": "9e9b755d63b36acf30c12a9a3fc379243714c1c6d3dd72861da637f336ebb35b",
    "linux_arm64": "b00b694903d126c588c378e72d3545549935d3982635ba3f7a964c9fa23fe3b9",
}


def _normalize_os(os_name):
    os_name = os_name.lower()
    if "linux" in os_name:
        return "linux"
    if "darwin" in os_name or "mac" in os_name:
        return "darwin"
    fail("unsupported TinyGo host OS: {}".format(os_name))


def _normalize_arch(arch):
    arch = arch.lower()
    if arch in ["amd64", "x86_64"]:
        return "amd64"
    if arch in ["aarch64", "arm64"]:
        return "arm64"
    fail("unsupported TinyGo host architecture: {}".format(arch))


def _tinygo_host_repository_impl(ctx):
    os_name = _normalize_os(ctx.os.name)
    arch = _normalize_arch(ctx.os.arch)
    host_platform = "{}_{}".format(os_name, arch)
    version = ctx.attr.version

    for platform, sha256 in _TINYGO_SHA256.items():
        platform_os, platform_arch = platform.split("_")
        filename = "tinygo{}.{}-{}.tar.gz".format(version, platform_os, platform_arch)
        ctx.download_and_extract(
            output = platform,
            url = "https://github.com/tinygo-org/tinygo/releases/download/v{}/{}".format(version, filename),
            sha256 = sha256,
        )

    # Must run after the TinyGo loop above: this extracts into an existing darwin_*/tinygo
    # tree, merging bin/wasm-opt and lib/libbinaryen.dylib alongside TinyGo's own files.
    for platform, sha256 in _BINARYEN_SHA256.items():
        asset = _BINARYEN_ASSET[platform]
        filename = "binaryen-version_{}-{}.tar.gz".format(_BINARYEN_VERSION, asset)
        ctx.download_and_extract(
            output = "{}/tinygo".format(platform),
            url = "https://github.com/WebAssembly/binaryen/releases/download/version_{}/{}".format(
                _BINARYEN_VERSION,
                filename,
            ),
            sha256 = sha256,
            stripPrefix = "binaryen-version_{}".format(_BINARYEN_VERSION),
        )

    for platform, sha256 in _GO_SHA256.items():
        platform_os, platform_arch = platform.split("_")
        filename = "go{}.{}-{}.tar.gz".format(_GO_VERSION, platform_os, platform_arch)
        ctx.download_and_extract(
            output = "go_{}".format(platform),
            url = "https://dl.google.com/go/{}".format(filename),
            sha256 = sha256,
        )

    host_tinygo_path = "{}/tinygo/bin/tinygo".format(host_platform)
    host_go_path = "go_{}/go/bin/go".format(host_platform)
    ctx.file(
        "BUILD.bazel",
        """
package(default_visibility = ["//visibility:public"])

filegroup(
    name = "tinygo_bin",
    srcs = ["{host_tinygo_path}"],
)

filegroup(
    name = "go_bin",
    srcs = ["{host_go_path}"],
)

filegroup(
    name = "tinygo_darwin_amd64_bin",
    srcs = ["darwin_amd64/tinygo/bin/tinygo"],
)

filegroup(
    name = "tinygo_darwin_arm64_bin",
    srcs = ["darwin_arm64/tinygo/bin/tinygo"],
)

filegroup(
    name = "tinygo_linux_amd64_bin",
    srcs = ["linux_amd64/tinygo/bin/tinygo"],
)

filegroup(
    name = "tinygo_linux_arm64_bin",
    srcs = ["linux_arm64/tinygo/bin/tinygo"],
)

filegroup(
    name = "go_darwin_amd64_bin",
    srcs = ["go_darwin_amd64/go/bin/go"],
)

filegroup(
    name = "go_darwin_arm64_bin",
    srcs = ["go_darwin_arm64/go/bin/go"],
)

filegroup(
    name = "go_linux_amd64_bin",
    srcs = ["go_linux_amd64/go/bin/go"],
)

filegroup(
    name = "go_linux_arm64_bin",
    srcs = ["go_linux_arm64/go/bin/go"],
)

filegroup(
    name = "files",
    srcs = glob(["**"]),
)
""".format(host_go_path = host_go_path, host_tinygo_path = host_tinygo_path),
    )


tinygo_host_repository = repository_rule(
    implementation = _tinygo_host_repository_impl,
    attrs = {
        "version": attr.string(default = "0.40.1"),
    },
)
