"""Linux agent packages with explicit binary transitions for every payload."""

load("@io_bazel_rules_go//go:def.bzl", "go_cross_binary")
load("@rules_pkg//pkg:mappings.bzl", "pkg_attributes", "pkg_files")
load("@rules_pkg//pkg:pkg.bzl", "pkg_tar")
load("//build/packaging:package_rules.bzl", "serviceradar_package_from_config")
load("//build/packaging:packages.bzl", "PACKAGES")

def declare_linux_agent_packages(architectures):
    """Keep existing amd64 labels and add ARM64 installers and managed runtime."""
    for arch in architectures:
        binaries = {}
        for component, target in {
            "agent": "//go/cmd/agent:agent",
            "updater": "//go/cmd/agent-updater:agent_updater",
            "srctl": "//go/cmd/cli:srctl",
        }.items():
            name = "{}_linux_{}".format(component, arch)
            go_cross_binary(
                name = name,
                target = target,
                platform = "@io_bazel_rules_go//go/toolchain:linux_{}".format(arch),
            )
            binaries[target] = ":" + name

        config = dict(PACKAGES["agent"])
        config["architecture"] = arch
        config["binary"] = dict(config["binary"], target = binaries[config["binary"]["target"]])
        config["files"] = [dict(entry, src = binaries.get(entry["src"], _agent_source(entry["src"]))) for entry in config["files"]]
        config["systemd"] = dict(config["systemd"], src = _agent_source(config["systemd"]["src"]))
        config["postinst"] = _agent_source(config["postinst"])
        config["prerm"] = _agent_source(config["prerm"])
        serviceradar_package_from_config(
            name = "agent" if arch == "amd64" else "agent_arm64",
            config = config,
        )

        runtime = "agent_release_runtime" if arch == "amd64" else "agent_release_runtime_linux_arm64"
        binary = binaries["//go/cmd/agent:agent"]
        pkg_files(
            name = runtime + "_files",
            srcs = [binary],
            attributes = pkg_attributes(mode = "0755"),
            prefix = "/",
            renames = {binary: "serviceradar-agent"},
        )
        pkg_tar(
            name = runtime + "_archive",
            srcs = [":" + runtime + "_files"],
            extension = "tar.gz",
            package_dir = "/",
        )

def _agent_source(path):
    return path if path.startswith("//") else "//build/packaging/agent:" + path
