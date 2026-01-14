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

    deb_targets = [
        "//packaging/{name}:{name}_deb".format(name = name)
        for name in component_names
    ]
    rpm_targets = [
        "//packaging/{name}:{name}_rpm".format(name = name)
        for name in component_names
    ]

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
