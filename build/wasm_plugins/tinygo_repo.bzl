"""Host TinyGo repository rule for first-party Wasm plugin builds."""

# 0.41 is a floor, not a preference. Up to 0.40.x, reflect's AssignableTo/Implements against an
# interface with methods panicked "unimplemented" (fixed by tinygo#5304), and encoding/json asks
# exactly that question of every type it encodes. A plugin binary that also linked errors.As
# then panicked on its first json.Marshal; proxmox-inventory died on its first successful
# inventory batch. //build/wasm_plugins:plugin_runtime_test fails if the pin regresses.
_TINYGO_SHA256 = {
    "darwin_amd64": "1a8e62a234d3aea20793ada2c4a628de96ed7533384f0f5dc3c3f2ffa84f9bab",
    "darwin_arm64": "c684d154d89a452cc9c7fc5dc5fc80cb6a42445b3e44b3c12ed048692de0f341",
    "linux_amd64": "e156d1d93a376eef639a4143d13be07e8c463fb6cf2d7d447698ed4474d23e91",
    "linux_arm64": "789733bc3b5bace0bd1835a267b3ea267804a7ef1cfe69bc522c295f5226d624",
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
# version_116 is not arbitrary. TinyGo v0.41.1 pins lib/binaryen at commit
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


def _tinygo_platform_repository_impl(ctx):
    """Fetches ONE platform's TinyGo + Go SDK (+ binaryen on darwin).

    One repo per platform, not one repo with every platform in it. Under bzlmod a repo is
    fetched only when a label inside it is demanded, and //build/wasm_plugins selects the
    matching one in the EXEC configuration -- so a build downloads a quarter of what the
    combined repo did. The combined repo unpacked 4 TinyGo toolchains and 4 Go SDKs on every
    fetch and used one; it was also ineligible for Bazel's repo contents cache, so all 5 GB
    was re-extracted on every cold output base.

    The intra-repo layout is deliberately unchanged (`<platform>/tinygo/bin/tinygo`,
    `go_<platform>/go/bin/go`) so build_wasm_binary.sh's own path handling still applies.
    """
    platform = ctx.attr.platform
    platform_os, platform_arch = platform.split("_")
    version = ctx.attr.version

    ctx.download_and_extract(
        output = platform,
        url = "https://github.com/tinygo-org/tinygo/releases/download/v{}/tinygo{}.{}-{}.tar.gz".format(
            version,
            version,
            platform_os,
            platform_arch,
        ),
        sha256 = _TINYGO_SHA256[platform],
    )

    # Must run after the TinyGo extraction above: it merges into that tree. See the note on
    # _BINARYEN_VERSION for why only darwin needs it.
    if platform in _BINARYEN_ASSET:
        ctx.download_and_extract(
            output = "{}/tinygo".format(platform),
            url = "https://github.com/WebAssembly/binaryen/releases/download/version_{}/binaryen-version_{}-{}.tar.gz".format(
                _BINARYEN_VERSION,
                _BINARYEN_VERSION,
                _BINARYEN_ASSET[platform],
            ),
            sha256 = _BINARYEN_SHA256[platform],
            stripPrefix = "binaryen-version_{}".format(_BINARYEN_VERSION),
        )

    ctx.download_and_extract(
        output = "go_{}".format(platform),
        url = "https://dl.google.com/go/go{}.{}-{}.tar.gz".format(_GO_VERSION, platform_os, platform_arch),
        sha256 = _GO_SHA256[platform],
    )

    ctx.file(
        "BUILD.bazel",
        """
package(default_visibility = ["//visibility:public"])

filegroup(
    name = "tinygo_bin",
    srcs = ["{platform}/tinygo/bin/tinygo"],
)

filegroup(
    name = "go_bin",
    srcs = ["go_{platform}/go/bin/go"],
)

filegroup(
    name = "files",
    srcs = glob(["**"]),
)
""".format(platform = platform),
    )


tinygo_platform_repository = repository_rule(
    implementation = _tinygo_platform_repository_impl,
    attrs = {
        "platform": attr.string(mandatory = True, values = sorted(_TINYGO_SHA256)),
        "version": attr.string(default = "0.41.1"),
    },
)
