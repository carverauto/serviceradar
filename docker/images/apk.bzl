"""Helpers for extracting Alpine APK artifacts into rootfs tarballs."""

def apk_rootfs_amd64(name, apk_target):
    """Generate an amd64 rootfs tar from an APK repository target.

    Args:
        name: Short rule suffix (for example "libcap2").
        apk_target: Label for the APK file target.
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
tar -czf "$@" -C "$${{TMP}}/rootfs" .
""".format(
            apk_target = apk_target,
            name = name,
        ),
    )
