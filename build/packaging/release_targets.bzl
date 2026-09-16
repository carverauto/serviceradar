"""Helpers to expose ServiceRadar packaging artifacts for release publishing."""

load("//build/packaging:packages.bzl", "PACKAGES", "RELEASE_PACKAGES")

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
    """Declares aggregate targets for Debian and RPM release artifacts.

    Only `RELEASE_PACKAGES` ship on the tagged GitHub release. Full `PACKAGES`
    entries remain buildable individually for ad-hoc packaging.
    """

    unknown = [name for name in RELEASE_PACKAGES if name not in PACKAGES]
    if unknown:
        fail("RELEASE_PACKAGES references unknown packages: %s" % unknown)

    component_names = sorted(RELEASE_PACKAGES)

    deb_targets = [
        "//build/packaging/{name}:{name}_deb".format(name = name)
        for name in component_names
    ]
    rpm_targets = [
        "//build/packaging/{name}:{name}_rpm".format(name = name)
        for name in component_names
    ]
    if "agent" in component_names:
        deb_targets.append("//build/packaging/agent:agent_arm64_deb")
        rpm_targets.append("//build/packaging/agent:agent_arm64_rpm")

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

    native.filegroup(
        name = "package_artifacts",
        srcs = deb_targets + rpm_targets,
        visibility = ["//visibility:public"],
    )

    package_manifest(
        name = "package_manifest",
        srcs = deb_targets + rpm_targets,
        visibility = ["//visibility:public"],
    )
