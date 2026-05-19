"""Host TinyGo repository rule for first-party Wasm plugin builds."""

_TINYGO_SHA256 = {
    "darwin_amd64": "36c9423a63f9548d142908b06c67e198d878a0fed076b8ec5dbf8a3350a73eb4",
    "darwin_arm64": "a20841a616de3b3403e52e3789cb60c147ab52b3fe6c33b31fdffba0164ae031",
    "linux_amd64": "064fc0c07f4d71f7369b168c337caa88ef32a6b00b16449cea44790ccadfc2b4",
    "linux_arm64": "4720693b333826569d5c1ed746a735c4d1983719c95af5bdd4d9dfeaa755e933",
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
    platform = "{}_{}".format(os_name, arch)
    version = ctx.attr.version

    filename = "tinygo{}.{}-{}.tar.gz".format(version, os_name, arch)
    ctx.download_and_extract(
        url = "https://github.com/tinygo-org/tinygo/releases/download/v{}/{}".format(version, filename),
        sha256 = _TINYGO_SHA256[platform],
    )
    ctx.file(
        "BUILD.bazel",
        """
package(default_visibility = ["//visibility:public"])

filegroup(
    name = "tinygo_bin",
    srcs = ["tinygo/bin/tinygo"],
)
""",
    )


tinygo_host_repository = repository_rule(
    implementation = _tinygo_host_repository_impl,
    attrs = {
        "version": attr.string(default = "0.40.1"),
    },
)
