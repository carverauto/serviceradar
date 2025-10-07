workspace(name = "serviceradar")

# All external dependencies are managed through MODULE.bazel (Bzlmod).
# Avoid declaring http_archive/git_repository here unless absolutely necessary.
http_archive(
    name = "io_buildbuddy_buildbuddy_toolchain",
    integrity = "sha256-VtJjefgP2Vq5S6DiGYczsupNkosybmSBGWwcLUAYz8c=",
    strip_prefix = "buildbuddy-toolchain-66146a3015faa348391fcceea2120caa390abe03",
    urls = ["https://github.com/buildbuddy-io/buildbuddy-toolchain/archive/66146a3015faa348391fcceea2120caa390abe03.tar.gz"],
)

load("@io_buildbuddy_buildbuddy_toolchain//:deps.bzl", "buildbuddy_deps")

buildbuddy_deps()

load("@io_buildbuddy_buildbuddy_toolchain//:rules.bzl", "buildbuddy")

buildbuddy(name = "buildbuddy_toolchain")
