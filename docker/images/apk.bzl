"""Helpers for extracting and combining Alpine APK rootfs tarballs."""

def apk_rootfs_amd64(name, apk_target, post_extract_cmd = "", visibility = None):
    """Generate an amd64 rootfs tar from an APK repository target.

    Args:
        name: Short rule suffix (for example "libcap2").
        apk_target: Label for the APK file target.
        post_extract_cmd: Optional shell snippet to run after unpacking.
        visibility: Optional target visibility.
    """
    native.genrule(
        name = "apk_{}_rootfs_amd64".format(name),
        srcs = [apk_target],
        outs = ["apk_{}_rootfs_amd64.tar".format(name)],
        cmd = """
set -euo pipefail
APK=$(location {apk_target})
TMP=$(@D)/{name}_extract
rm -rf "$${{TMP}}"
mkdir -p "$${{TMP}}/extracted" "$${{TMP}}/rootfs"
tar -xzf "$${{APK}}" -C "$${{TMP}}/extracted"
DATA_TAR=$$(find "$${{TMP}}/extracted" -maxdepth 1 -type f -name 'data.tar.*' -print -quit)
if [ -n "$${{DATA_TAR}}" ]; then
  tar -axf "$${{DATA_TAR}}" -C "$${{TMP}}/rootfs"
else
  shopt -s nullglob
  for entry in "$${{TMP}}/extracted"/*; do
    base=$$(basename "$${{entry}}")
    case "$${{base}}" in
      .SIGN*|.PKGINFO) continue ;;
    esac
    cp -a "$${{entry}}" "$${{TMP}}/rootfs/"
  done
fi
{post_extract_cmd}
# Normalise mtimes before tarring, or this layer changes on every cache miss. The APK's own
# files carry the packager's fixed mtimes and are fine, but the directories this genrule
# creates (`mkdir -p .../rootfs`, and anything post_extract_cmd adds) get wall-clock times --
# measured as a single "." entry at build time, which is enough to change the tar bytes, the
# layer and the image digest. 200001010000.00 matches rules_pkg's PORTABLE_MTIME so this
# agrees with layers built from declared files. POSIX `touch -t`; `-h` is not POSIX, hence
# the fallback, and it matters for symlinks inside the package.
find "$${{TMP}}/rootfs" -exec touch -h -t 200001010000.00 {{}} + 2>/dev/null || \
  find "$${{TMP}}/rootfs" -exec touch -t 200001010000.00 {{}} +
tar -czf "$@" -C "$${{TMP}}/rootfs" .
""".format(
            apk_target = apk_target,
            name = name,
            post_extract_cmd = post_extract_cmd,
        ),
        visibility = visibility,
    )

def declare_apk_rootfs_targets(entries, visibility = None):
    """Declare multiple amd64 APK rootfs targets.

    Args:
        entries: Sequence of `(name, apk_target)` tuples.
        visibility: Optional target visibility applied to each target.
    """

    for name, apk_target in entries:
        apk_rootfs_amd64(
            name = name,
            apk_target = apk_target,
            visibility = visibility,
        )

def merged_rootfs_amd64(name, srcs, visibility = None):
    """Merge multiple rootfs tarballs into a single tarball."""

    native.genrule(
        name = name,
        srcs = srcs,
        outs = ["{}.tar".format(name)],
        cmd = """
set -euo pipefail
ROOT=$(@D)/{name}_root
rm -rf "$${{ROOT}}"
mkdir -p "$${{ROOT}}"
for tarfile in $(SRCS); do
  tar -xzf "$${{tarfile}}" -C "$${{ROOT}}"
done
# Same normalisation as apk_rootfs_amd64 above, and needed for the same reason: `mkdir -p`
# stamps this merge root with wall-clock time, which alone changes the tar bytes and the
# resulting image digest on every cache miss.
find "$${{ROOT}}" -exec touch -h -t 200001010000.00 {{}} + 2>/dev/null || \
  find "$${{ROOT}}" -exec touch -t 200001010000.00 {{}} +
tar -czf "$@" -C "$${{ROOT}}" .
""".format(name = name),
        visibility = visibility,
    )

def declare_alpine_netutils_rootfs_amd64(
        name = "alpine_netutils_rootfs_amd64",
        visibility = None):
    """Declare the shared Alpine netutils rootfs bundle."""

    merged_rootfs_amd64(
        name = name,
        srcs = [
            ":apk_iputils_ping_rootfs_amd64.tar",
            ":apk_libcap2_rootfs_amd64.tar",
            ":apk_libpcap_rootfs_amd64.tar",
            ":apk_glibc_rootfs_amd64",
            ":apk_libmd_rootfs_amd64.tar",
            ":apk_libbsd_rootfs_amd64.tar",
            ":apk_nmap_rootfs_amd64.tar",
            ":apk_netcat_rootfs_amd64.tar",
            ":apk_inetutils_telnet_rootfs_amd64.tar",
        ],
        visibility = visibility,
    )
