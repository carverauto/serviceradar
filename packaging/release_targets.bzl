"""Helpers to expose ServiceRadar packaging artifacts for release publishing."""

load("//packaging:packages.bzl", "PACKAGES")

def _manifest_impl(ctx):
    files = depset()
    for target in ctx.attr.srcs:
        files = depset(transitive = [files, target.files])

    file_list = sorted([f.short_path for f in files.to_list()])
    content = "\n".join(file_list)
    if content:
        content += "\n"

    ctx.actions.write(output = ctx.outputs.manifest, content = content)

    return [DefaultInfo(files = depset([ctx.outputs.manifest]))]

package_manifest = rule(
    implementation = _manifest_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = True),
    },
    outputs = {"manifest": "%{name}.txt"},
)

def declare_release_artifacts():
    """Declares aggregate targets for Debian and RPM release artifacts."""

    component_names = sorted(PACKAGES.keys())

    # sysmon requires --config=el9 due to ZFS binary dependency
    # It's separated so it can be built with the correct platform
    el9_components = ["sysmon"]
    standard_components = [name for name in component_names if name not in el9_components]

    deb_targets = [
        "//packaging/{name}:{name}_deb".format(name = name)
        for name in standard_components
    ]
    rpm_targets = [
        "//packaging/{name}:{name}_rpm".format(name = name)
        for name in standard_components
    ]

    el9_deb_targets = [
        "//packaging/{name}:{name}_deb".format(name = name)
        for name in el9_components
    ]
    el9_rpm_targets = [
        "//packaging/{name}:{name}_rpm".format(name = name)
        for name in el9_components
    ]

    mac_pkg_targets = ["//packaging/sysmonosx_host:sysmonosx_host_pkg"]
    mac_pkg_select = select({
        "@platforms//os:macos": mac_pkg_targets,
        "//conditions:default": [],
    })

    native.filegroup(
        name = "package_debs",
        srcs = deb_targets,
        visibility = ["//visibility:public"],
    )

    native.filegroup(
        name = "package_rpms",
        srcs = rpm_targets,
        visibility = ["//visibility:public"],
    )

    # EL9 packages (sysmon) - requires --config=el9 to build
    native.filegroup(
        name = "package_el9_debs",
        srcs = el9_deb_targets,
        visibility = ["//visibility:public"],
    )

    native.filegroup(
        name = "package_el9_rpms",
        srcs = el9_rpm_targets,
        visibility = ["//visibility:public"],
    )

    native.filegroup(
        name = "package_el9",
        srcs = el9_deb_targets + el9_rpm_targets,
        visibility = ["//visibility:public"],
    )

    native.filegroup(
        name = "package_artifacts",
        srcs = deb_targets + rpm_targets + mac_pkg_select,
        visibility = ["//visibility:public"],
    )

    # All packages including EL9 - only use with proper platform config
    native.filegroup(
        name = "package_artifacts_all",
        srcs = deb_targets + rpm_targets + el9_deb_targets + el9_rpm_targets + mac_pkg_select,
        visibility = ["//visibility:public"],
    )

    native.filegroup(
        name = "package_macos",
        srcs = mac_pkg_select,
        visibility = ["//visibility:public"],
    )

    package_manifest(
        name = "package_manifest",
        srcs = deb_targets + rpm_targets + mac_pkg_select,
        visibility = ["//visibility:public"],
    )

    package_manifest(
        name = "package_manifest_el9",
        srcs = el9_deb_targets + el9_rpm_targets,
        visibility = ["//visibility:public"],
    )

    package_manifest(
        name = "package_manifest_all",
        srcs = deb_targets + rpm_targets + el9_deb_targets + el9_rpm_targets + mac_pkg_select,
        visibility = ["//visibility:public"],
    )
