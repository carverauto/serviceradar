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
    """Emit a build-info JSON file and wrap it as a layer tar.

    CONTENT IS A PURE FUNCTION OF DECLARED INPUTS. This layer goes INSIDE the image, so
    anything non-deterministic here changes the layer tar, the image config, and therefore
    the image digest -- on every build, for an image whose code did not change. That defeats
    the whole point of addressing images by digest.

    Two volatile sources were removed:

      * `buildTime`, from `${BUILD_TIMESTAMP:-$(date -u ...)}`. BUILD_TIMESTAMP is a
        WORKSPACE STATUS KEY, not an environment variable -- scripts/workspace_status.sh
        emits it without a STABLE_ prefix, so it lands in volatile-status.txt and never in
        an action's env. The `:-` fallback therefore always fired and the field was simply
        `date` at execution time, making the digest change on EVERY build. Reading the
        volatile key properly would have been no better: Bazel keeps volatile keys out of
        action keys precisely so they cannot invalidate anything, and baking one into an
        output defeats that.

      * STABLE_COMMIT_SHA, read out of `bazel-out/stable-status.txt` by hardcoded path.
        That moved the digest on every commit even when no input changed, and the path is
        not a declared input -- when absent the script silently substituted "dev" rather
        than failing, so a wrong value looked like a correct one.

    What remains is derived from declared inputs only: VERSION (a source file) and the base
    image digest. `webBuildId` is now the DIGEST short form, which is what it should have
    been -- it identifies the artifact rather than the commit that happened to produce it.
    """

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
        cmd = """
set -euo pipefail

web_digest_file="$(location ___WEB_DIGEST___)"
version_file="$(location ___VERSION_FILE___)"

web_digest=$$(cat "$$web_digest_file")
if [[ "$$web_digest" != sha256:* ]]; then
  echo "unexpected web digest format: $$web_digest" >&2
  exit 1
fi

web_short=$${web_digest#sha256:}
web_short=$$(printf '%s' "$$web_short" | cut -c1-12)

version=$$(tr -d '\\n' < "$$version_file")

cat > "$@" <<EOF
{
  "version": "$$version",
  "webBuildId": "sha-$$web_short",
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
    # Still gzipped, via extension, to keep the layer bytes' shape as close to the previous
    # behaviour as possible -- the win here is the removed extract and touch passes, not the
    # compression. Consumers take this by LABEL (image_rootfs_tar below), so the output file
    # renaming from .tar to .tar.gz reaches nothing.
    # No `mode` here, deliberately. It governs entries pkg_tar creates from `files`/`srcs`,
    # of which this target has none -- everything arrives via `deps` and keeps its own mode
    # (0644 files, 0755 dirs). Setting it was tried and changed nothing.
    #
    # The /app entry itself is not synthesized either: add_tar() hardcodes mode=0o755 for
    # parents it invents, so /app comes from the release tar's own `./` root entry. That was
    # 0700 because //build:elixir_release.bzl built the tree in a `mktemp -d`; it is chmod'd
    # to 755 there now, at the source, where every consumer of that tar benefits.
    pkg_tar(
        name = name,
        extension = "tar.gz",
        package_dir = "/app",
        visibility = visibility,
        deps = [release_tar],
    )

def elixir_release_rootfs_with_debs_amd64(
        name,
        release_tar,
        deb_packages,
        overlay_tool = "//docker/images:overlay_deb_packages.py",
        zstd_tool = "@zstd//:zstd_cli",
        visibility = None):
    """Wrap an Elixir release under /app and overlay Debian packages into rootfs."""

    deb_args = ""
    if deb_packages:
        deb_args = """
python3 "$(location {overlay_tool})" --zstd "$(location {zstd_tool})" "$${{ROOT}}" \\
  {deb_locations}
""".format(
            overlay_tool = overlay_tool,
            zstd_tool = zstd_tool,
            deb_locations = " \\\n  ".join(["$(locations {})".format(pkg) for pkg in deb_packages]),
        )

    native.genrule(
        name = name,
        srcs = [release_tar] + deb_packages,
        outs = ["{}.tar".format(name)],
        tools = [overlay_tool, zstd_tool],
        cmd = """
set -euo pipefail
TAR=$(location ___RELEASE_TAR___)
ROOT=$(@D)/rootfs
rm -rf "$${{ROOT}}"
mkdir -p "$${{ROOT}}/app"
tar -xzf "$${{TAR}}" -C "$${{ROOT}}/app"
# Normalise mtimes before tarring, after the deb overlay has run. Same `mkdir -p` problem as
# elixir_release_rootfs_amd64 above, plus overlay_deb_packages.py writes every file,
# directory and symlink without reading the deb member's mtime, so the overlaid tree carries
# build time throughout. The `-h` form matters for the symlinks the overlay creates.
{deb_args}find "$${{ROOT}}" -exec touch -h -t 200001010000.00 {{}} + 2>/dev/null || \
  find "$${{ROOT}}" -exec touch -t 200001010000.00 {{}} +
tar -czf "$@" --owner=10001 --group=10001 -C "$${{ROOT}}" .
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
        cosign_src = "@cosign_linux_amd64//file",
        cmd = None,
        env = None,
        workdir = "/app",
        exposed_ports = None,
        extra_tars = None,
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

    cosign_layer_name = (
        name[:-len("_image_amd64")] + "_cosign_runtime_layer_amd64"
        if name.endswith("_image_amd64")
        else name + "_cosign_runtime_layer_amd64"
    )
    ca_bundle_layer_name = (
        name[:-len("_image_amd64")] + "_ca_bundle_layer_amd64"
        if name.endswith("_image_amd64")
        else name + "_ca_bundle_layer_amd64"
    )
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

    file_layer_amd64(
        name = cosign_layer_name,
        src = cosign_src,
        target_path = "usr/local/bin/cosign",
        visibility = visibility,
        target_compatible_with = target_compatible_with,
    )

    file_layer_amd64(
        name = ca_bundle_layer_name,
        src = "@mozilla_ca_bundle//file",
        target_path = "etc/ssl/certs/ca-certificates.crt",
        visibility = visibility,
        target_compatible_with = target_compatible_with,
    )

    if extra_tars == None:
        extra_tars = []

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
            ":{}".format(cosign_layer_name),
            ":{}".format(ca_bundle_layer_name),
        ] + extra_tars,
        base_image_name = base_image_name,
        visibility = visibility,
        target_compatible_with = target_compatible_with,
    )
