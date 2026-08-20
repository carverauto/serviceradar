"""Helpers for extracting and combining Alpine APK rootfs tarballs."""

def arm64_apk_label(apk_target):
    """Map an amd64 APK repository label to its arm64 sibling.

    Every Alpine APK repository in MODULE.bazel is declared as `<name>_apk` pinning the
    x86_64 build, with a `<name>_apk_arm64` sibling pinning the identical package version
    for aarch64. The two differ only in the `/x86_64/` -> `/aarch64/` path segment and the
    checksum, so the label mapping is mechanical rather than a second inventory to maintain.

    Args:
        apk_target: Label of the amd64 APK file target, e.g. `@alpine_bash_apk//file`.

    Returns:
        The corresponding arm64 label, e.g. `@alpine_bash_apk_arm64//file`.
    """
    if not apk_target.startswith("@") or "//" not in apk_target:
        fail("expected an APK file label like @foo_apk//file, got '{}'".format(apk_target))
    repo, _, rest = apk_target.partition("//")
    return "{}_arm64//{}".format(repo, rest)

def apk_rootfs(name, apk_target, arch = "amd64", post_extract_cmd = "", visibility = None):
    """Generate a rootfs tar for one architecture from an APK repository target.

    Args:
        name: Short rule suffix (for example "libcap2").
        apk_target: Label for the APK file target.
        arch: Target architecture suffix, "amd64" or "arm64".
        post_extract_cmd: Optional shell snippet to run after unpacking.
        visibility: Optional target visibility.
    """
    native.genrule(
        name = "apk_{}_rootfs_{}".format(name, arch),
        srcs = [apk_target],
        outs = ["apk_{}_rootfs_{}.tar".format(name, arch)],
        cmd = """
set -euo pipefail
APK=$(location {apk_target})
TMP=$(@D)/{name}_{arch}_extract
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
            arch = arch,
            name = name,
            post_extract_cmd = post_extract_cmd,
        ),
        visibility = visibility,
    )

def apk_rootfs_amd64(name, apk_target, post_extract_cmd = "", visibility = None):
    """Generate an amd64-only rootfs tar.

    For packages that exist for x86_64 alone. Anything with an aarch64 build should go
    through `declare_apk_rootfs_targets`, which declares both architectures.

    Args:
        name: Short rule suffix (for example "glibc").
        apk_target: Label for the APK file target.
        post_extract_cmd: Optional shell snippet to run after unpacking.
        visibility: Optional target visibility.
    """
    apk_rootfs(
        name = name,
        apk_target = apk_target,
        arch = "amd64",
        post_extract_cmd = post_extract_cmd,
        visibility = visibility,
    )

def declare_apk_rootfs_targets(entries, visibility = None):
    """Declare amd64 and arm64 APK rootfs targets for each entry.

    Args:
        entries: Sequence of `(name, apk_target)` tuples naming the amd64 APK label.
        visibility: Optional target visibility applied to each target.
    """

    for name, apk_target in entries:
        apk_rootfs(
            name = name,
            apk_target = apk_target,
            arch = "amd64",
            visibility = visibility,
        )
        apk_rootfs(
            name = name,
            apk_target = arm64_apk_label(apk_target),
            arch = "arm64",
            visibility = visibility,
        )

def merged_rootfs(name, srcs, visibility = None):
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
# Same normalisation as apk_rootfs above, and needed for the same reason: `mkdir -p`
# stamps this merge root with wall-clock time, which alone changes the tar bytes and the
# resulting image digest on every cache miss.
find "$${{ROOT}}" -exec touch -h -t 200001010000.00 {{}} + 2>/dev/null || \
  find "$${{ROOT}}" -exec touch -t 200001010000.00 {{}} +
tar -czf "$@" -C "$${{ROOT}}" .
""".format(name = name),
        visibility = visibility,
    )

# Packages shared by the netutils bundle on both architectures.
#
# glibc is deliberately absent. It was only ever here to load a glibc-dynamic netprobe;
# that binary is now static musl (see //rust/netprobe:netprobe_linux_*_musl and the alias
# in this package), and the sgerrand alpine-pkg-glibc APK that provided it is x86_64-only
# with no aarch64 build in any release, so keeping it would pin this bundle to amd64.
_NETUTILS_PACKAGES = [
    "iputils_ping",
    "libcap2",
    "libpcap",
    "libmd",
    "libbsd",
    "nmap",
    "netcat",
    "inetutils_telnet",
]

def declare_alpine_netutils_rootfs(name = "alpine_netutils_rootfs", visibility = None):
    """Declare the shared Alpine netutils rootfs bundle for both architectures.

    Args:
        name: Base target name; each architecture is suffixed onto it.
        visibility: Optional target visibility applied to each target.
    """

    for arch in ["amd64", "arm64"]:
        merged_rootfs(
            name = "{}_{}".format(name, arch),
            srcs = [
                ":apk_{}_rootfs_{}.tar".format(pkg, arch)
                for pkg in _NETUTILS_PACKAGES
            ],
            visibility = visibility,
        )
