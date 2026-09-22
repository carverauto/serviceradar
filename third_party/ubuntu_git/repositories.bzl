"""Fetch the pinned Git runtime packages without depending on a host apt install."""

load(":packages.bzl", "GIT_RUNTIME_PACKAGES")

def _git_runtime_repository_impl(repository_ctx):
    arch = repository_ctx.attr.arch
    mirror = (
        "https://mirrors.edge.kernel.org/ubuntu/" if arch == "amd64" else "https://ports.ubuntu.com/ubuntu-ports/"
    )
    for path, sha256 in GIT_RUNTIME_PACKAGES[arch]:
        repository_ctx.download(
            url = [
                "https://snapshot.ubuntu.com/ubuntu/20260908T000000Z/" + path,
                mirror + path,
            ],
            output = path.split("/")[-1],
            sha256 = sha256,
        )
    repository_ctx.file("BUILD.bazel", """
package(default_visibility = ["//visibility:public"])
filegroup(name = "packages", srcs = glob(["*.deb"]))
""")

_git_runtime_repository = repository_rule(
    implementation = _git_runtime_repository_impl,
    attrs = {"arch": attr.string(mandatory = True, values = ["amd64", "arm64"])},
)

def _ubuntu_git_impl(_module_ctx):
    for arch in ["amd64", "arm64"]:
        _git_runtime_repository(name = "ubuntu_git_runtime_" + arch, arch = arch)

ubuntu_git = module_extension(implementation = _ubuntu_git_impl)
