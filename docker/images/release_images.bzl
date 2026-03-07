"""Shared helpers for Bazel-native OCI images backed by Elixir releases."""

load("@rules_oci//oci:defs.bzl", "oci_image", "oci_load")

def elixir_release_rootfs_amd64(name, release_tar, visibility = None):
    """Wrap an Elixir release tarball under /app for OCI packaging."""

    native.genrule(
        name = name,
        srcs = [release_tar],
        outs = ["{}.tar".format(name)],
        cmd = """
set -euo pipefail
TAR=$(location ___RELEASE_TAR___)
ROOT=$(@D)/rootfs
rm -rf "$${ROOT}"
mkdir -p "$${ROOT}/app"
tar -xzf "$${TAR}" -C "$${ROOT}/app"
tar -czf "$@" -C "$${ROOT}" .
""".replace("___RELEASE_TAR___", release_tar),
        visibility = visibility,
    )

def elixir_release_rootfs_with_debs_amd64(
        name,
        release_tar,
        deb_packages,
        overlay_tool = "//docker/images:overlay_deb_packages.py",
        visibility = None):
    """Wrap an Elixir release under /app and overlay Debian packages into rootfs."""

    deb_args = ""
    if deb_packages:
        deb_args = """
python3 "$(location {overlay_tool})" "$${{ROOT}}" \\
  {deb_locations}
""".format(
            overlay_tool = overlay_tool,
            deb_locations = " \\\n  ".join(['"$(location {})"'.format(pkg) for pkg in deb_packages]),
        )

    native.genrule(
        name = name,
        srcs = [release_tar] + deb_packages,
        outs = ["{}.tar".format(name)],
        tools = [overlay_tool],
        cmd = """
set -euo pipefail
TAR=$(location ___RELEASE_TAR___)
ROOT=$(@D)/rootfs
rm -rf "$${{ROOT}}"
mkdir -p "$${{ROOT}}/app"
tar -xzf "$${{TAR}}" -C "$${{ROOT}}/app"
{deb_args}tar -czf "$@" -C "$${{ROOT}}" .
""".format(
            deb_args = deb_args,
        ).replace("___RELEASE_TAR___", release_tar),
        visibility = visibility,
    )

def elixir_release_image_amd64(
        name,
        base,
        rootfs_tar,
        entrypoint,
        image_title,
        cmd = None,
        env = None,
        workdir = "/app",
        exposed_ports = None,
        extra_tars = None,
        base_image_name = None,
        visibility = None,
        target_compatible_with = None):
    """Build an amd64 OCI image from an Elixir release rootfs tar."""

    if cmd == None:
        cmd = ["start"]
    if env == None:
        env = {}
    if exposed_ports == None:
        exposed_ports = []
    if extra_tars == None:
        extra_tars = []
    if target_compatible_with == None:
        target_compatible_with = []

    labels = {
        "org.opencontainers.image.title": image_title,
    }

    if base_image_name:
        oci_image(
            name = base_image_name,
            base = base,
            tars = [rootfs_tar],
            entrypoint = entrypoint,
            cmd = cmd,
            env = env,
            workdir = workdir,
            exposed_ports = exposed_ports,
            labels = labels,
            visibility = visibility,
            target_compatible_with = target_compatible_with,
        )

        oci_image(
            name = name,
            base = ":{}".format(base_image_name),
            tars = extra_tars,
            entrypoint = entrypoint,
            cmd = cmd,
            env = env,
            workdir = workdir,
            exposed_ports = exposed_ports,
            labels = labels,
            visibility = visibility,
            target_compatible_with = target_compatible_with,
        )
        return

    oci_image(
        name = name,
        base = base,
        tars = [rootfs_tar] + extra_tars,
        entrypoint = entrypoint,
        cmd = cmd,
        env = env,
        workdir = workdir,
        exposed_ports = exposed_ports,
        labels = labels,
        visibility = visibility,
        target_compatible_with = target_compatible_with,
    )

def declare_elixir_release_container_amd64(
        name,
        base,
        entrypoint,
        image_title,
        local_repo_tag,
        release_tar = None,
        rootfs_tar = None,
        rootfs_name = None,
        cmd = None,
        env = None,
        workdir = "/app",
        exposed_ports = None,
        extra_tars = None,
        base_image_name = None,
        visibility = None,
        target_compatible_with = None):
    """Declare an Elixir release image and matching local oci_load target."""

    if (release_tar == None) == (rootfs_tar == None):
        fail("exactly one of release_tar or rootfs_tar must be provided")

    if release_tar != None:
        if rootfs_name == None:
            if name.endswith("_image_amd64"):
                rootfs_name = name[:-len("_image_amd64")] + "_release_rootfs_amd64"
            else:
                rootfs_name = name + "_release_rootfs_amd64"

        elixir_release_rootfs_amd64(
            name = rootfs_name,
            release_tar = release_tar,
            visibility = visibility,
        )
        image_rootfs_tar = ":{}".format(rootfs_name)
    else:
        image_rootfs_tar = rootfs_tar

    elixir_release_image_amd64(
        name = name,
        base = base,
        rootfs_tar = image_rootfs_tar,
        entrypoint = entrypoint,
        image_title = image_title,
        cmd = cmd,
        env = env,
        workdir = workdir,
        exposed_ports = exposed_ports,
        extra_tars = extra_tars,
        base_image_name = base_image_name,
        visibility = visibility,
        target_compatible_with = target_compatible_with,
    )

    oci_load(
        name = "{}_tar".format(name),
        image = ":{}".format(name),
        repo_tags = [local_repo_tag],
        visibility = visibility,
    )
