"""Module extension for reading VERSION file at repository load time."""

def _version_repo_impl(repository_ctx):
    """Repository rule that reads VERSION and creates a build file exposing it."""
    version_file = repository_ctx.path(repository_ctx.attr.version_file)
    version = repository_ctx.read(version_file).strip()

    # Parse version and release (e.g., "1.0.65" or "1.0.65-rc1")
    if "-" in version:
        base_version, release = version.split("-", 1)
    else:
        base_version = version
        release = "1"

    # Create BUILD.bazel with version info
    repository_ctx.file("BUILD.bazel", content = """
load("@rules_pkg//pkg:providers.bzl", "PackageVariablesInfo")

# Expose version as a provider for pkg_rpm package_file_name substitution
def _version_variables_impl(ctx):
    return [PackageVariablesInfo(values = {
        "version": "%s",
        "release": "%s",
    })]

version_variables = rule(
    implementation = _version_variables_impl,
    attrs = {},
)

version_variables(
    name = "variables",
    visibility = ["//visibility:public"],
)

# Also expose as simple text files for other uses
genrule(
    name = "version_file",
    outs = ["VERSION"],
    cmd = "echo -n '%s' > $@",
    visibility = ["//visibility:public"],
)

genrule(
    name = "release_file",
    outs = ["RELEASE"],
    cmd = "echo -n '%s' > $@",
    visibility = ["//visibility:public"],
)
""" % (base_version, release, base_version, release))

    # Also create a .bzl file that can be loaded
    repository_ctx.file("defs.bzl", content = """
VERSION = "%s"
RELEASE = "%s"
FULL_VERSION = "%s"
""" % (base_version, release, version))

_version_repo = repository_rule(
    implementation = _version_repo_impl,
    attrs = {
        "version_file": attr.label(
            mandatory = True,
            allow_single_file = True,
        ),
    },
    local = True,  # Re-evaluate when VERSION file changes
)

def _version_extension_impl(module_ctx):
    """Module extension implementation."""
    # Find the root module's VERSION file
    for mod in module_ctx.modules:
        if mod.is_root:
            _version_repo(
                name = "serviceradar_version",
                version_file = Label("//:VERSION"),
            )
            break

version_ext = module_extension(
    implementation = _version_extension_impl,
)
