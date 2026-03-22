"""Shared helpers for Bazel-native OCI images backed by Elixir releases."""

load("@rules_oci//oci:defs.bzl", "oci_image", "oci_load")
load("@rules_pkg//pkg:pkg.bzl", "pkg_tar")

def file_layer_amd64(
        name,
        src,
        target_path,
        mode = "0755",
        visibility = None,
        target_compatible_with = None):
    """Package a single file into a rootfs layer tar."""

    if target_compatible_with == None:
        target_compatible_with = []

    pkg_tar(
        name = name,
        files = {
            src: target_path,
        },
        modes = {
            target_path: mode,
        },
        package_dir = "/",
        visibility = visibility,
        target_compatible_with = target_compatible_with,
    )

def elixir_build_info_layer_amd64(
        name,
        web_digest,
        version_file = "//:VERSION",
        target_path = "app/priv/static/build-info.json",
        visibility = None,
        target_compatible_with = None):
    """Emit a build-info JSON file and wrap it as a layer tar."""

    if target_compatible_with == None:
        target_compatible_with = []

    json_name = "{}_json".format(name)

    native.genrule(
        name = json_name,
        srcs = [
            web_digest,
            version_file,
        ],
        outs = ["{}.json".format(name)],
        stamp = True,
        cmd = """
set -euo pipefail

web_digest_file="$(location ___WEB_DIGEST___)"
version_file="$(location ___VERSION_FILE___)"
info_file="bazel-out/stable-status.txt"

web_digest=$$(cat "$$web_digest_file")
if [[ "$$web_digest" != sha256:* ]]; then
  echo "unexpected web digest format: $$web_digest" >&2
  exit 1
fi

web_short=$${web_digest#sha256:}
web_short=$$(printf '%s' "$$web_short" | cut -c1-12)

commit_sha="dev"
if [[ -f "$$info_file" ]]; then
  commit_sha=$$(grep -m1 '^STABLE_COMMIT_SHA ' "$$info_file" | awk '{print $$2}')
  if [[ -z "$$commit_sha" ]]; then
    commit_sha="dev"
  fi
fi
commit_short=$$(printf '%s' "$$commit_sha" | cut -c1-12)

if [[ -f "$$version_file" ]]; then
  version=$$(tr -d '\\n' < "$$version_file")
else
  version="dev"
fi

build_time="$${BUILD_TIMESTAMP:-$$(date -u +"%Y-%m-%dT%H:%M:%SZ")}"

cat > "$@" <<EOF
{
  "version": "$$version",
  "buildTime": "$$build_time",
  "webBuildId": "sha-$$commit_short",
  "webImageDigest": "$$web_digest"
}
EOF
""".replace("___WEB_DIGEST___", web_digest).replace("___VERSION_FILE___", version_file),
        visibility = visibility,
        target_compatible_with = target_compatible_with,
    )

    pkg_tar(
        name = name,
        files = {
            ":{}".format(json_name): target_path,
        },
        modes = {
            target_path: "0644",
        },
        package_dir = "/",
        visibility = visibility,
        target_compatible_with = target_compatible_with,
    )

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
tar -czf "$@" --owner=10001 --group=10001 -C "$${ROOT}" .
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
{deb_args}tar -czf "$@" --owner=10001 --group=10001 -C "$${{ROOT}}" .
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
        user = "10001",
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

    user_layer = "//docker/images:serviceradar_user_layer"

    if base_image_name:
        oci_image(
            name = base_image_name,
            base = base,
            tars = [user_layer, rootfs_tar],
            entrypoint = entrypoint,
            cmd = cmd,
            env = env,
            workdir = workdir,
            user = user,
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
            user = user,
            exposed_ports = exposed_ports,
            labels = labels,
            visibility = visibility,
            target_compatible_with = target_compatible_with,
        )
        return

    oci_image(
        name = name,
        base = base,
        tars = [user_layer, rootfs_tar] + extra_tars,
        entrypoint = entrypoint,
        cmd = cmd,
        env = env,
        workdir = workdir,
        user = user,
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

def declare_elixir_release_container_with_debs_amd64(
        name,
        base,
        release_tar,
        deb_packages,
        entrypoint,
        image_title,
        local_repo_tag,
        rootfs_name = None,
        cmd = None,
        env = None,
        workdir = "/app",
        exposed_ports = None,
        extra_tars = None,
        visibility = None,
        target_compatible_with = None):
    """Declare an Elixir release image whose rootfs overlays Debian packages."""

    if rootfs_name == None:
        if name.endswith("_image_amd64"):
            rootfs_name = name[:-len("_image_amd64")] + "_rootfs_amd64"
        else:
            rootfs_name = name + "_rootfs_amd64"

    elixir_release_rootfs_with_debs_amd64(
        name = rootfs_name,
        release_tar = release_tar,
        deb_packages = deb_packages,
        visibility = visibility,
    )

    declare_elixir_release_container_amd64(
        name = name,
        base = base,
        rootfs_tar = ":{}".format(rootfs_name),
        entrypoint = entrypoint,
        image_title = image_title,
        local_repo_tag = local_repo_tag,
        cmd = cmd,
        env = env,
        workdir = workdir,
        exposed_ports = exposed_ports,
        extra_tars = extra_tars,
        visibility = visibility,
        target_compatible_with = target_compatible_with,
    )

def declare_web_ng_release_container_amd64(
        name,
        base,
        release_tar,
        local_repo_tag,
        image_title = "serviceradar-web-ng",
        base_image_name = None,
        build_info_layer_name = None,
        bun_layer_name = None,
        bun_src = "@bun_linux_amd64//:bun",
        cmd = None,
        env = None,
        workdir = "/app",
        exposed_ports = None,
        visibility = None,
        target_compatible_with = None):
    """Declare the web-ng release image with build-info and Bun SSR layers."""

    if build_info_layer_name == None:
        if name.endswith("_image_amd64"):
            build_info_layer_name = name[:-len("_image_amd64")] + "_build_info_layer_amd64"
        else:
            build_info_layer_name = name + "_build_info_layer_amd64"

    if bun_layer_name == None:
        if name.endswith("_image_amd64"):
            bun_layer_name = name[:-len("_image_amd64")] + "_bun_runtime_layer_amd64"
        else:
            bun_layer_name = name + "_bun_runtime_layer_amd64"

    base_digest = ":{}.digest".format(base_image_name) if base_image_name else ":{}.digest".format(name)

    elixir_build_info_layer_amd64(
        name = build_info_layer_name,
        web_digest = base_digest,
        visibility = visibility,
        target_compatible_with = target_compatible_with,
    )

    file_layer_amd64(
        name = bun_layer_name,
        src = bun_src,
        target_path = "usr/local/bin/bun",
        visibility = visibility,
        target_compatible_with = target_compatible_with,
    )

    declare_elixir_release_container_amd64(
        name = name,
        base = base,
        release_tar = release_tar,
        entrypoint = ["/app/bin/serviceradar_web_ng"],
        cmd = cmd,
        env = env,
        workdir = workdir,
        exposed_ports = exposed_ports,
        image_title = image_title,
        local_repo_tag = local_repo_tag,
        extra_tars = [
            ":{}".format(build_info_layer_name),
            ":{}".format(bun_layer_name),
        ],
        base_image_name = base_image_name,
        visibility = visibility,
        target_compatible_with = target_compatible_with,
    )
