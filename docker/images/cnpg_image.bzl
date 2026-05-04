"""Custom CNPG OCI image graph.

This remains the explicit exception path while the rest of docker/images
converges on shared service/release image macros.
"""

load("@rules_oci//oci:defs.bzl", "oci_image", "oci_load")

def declare_cnpg_image_amd64():
    """Declare the custom CNPG image and its supporting layers."""

    native.genrule(
        name = "cnpg_postgresql_18_rootfs_tar",
        srcs = ["@cloudnativepg_postgresql_18_linux_amd64//:cloudnativepg_postgresql_18_linux_amd64"],
        tools = [
            "//docker/images:export_rootfs_from_layout.py",
            "//docker/images:extract_rootfs.py",
        ],
        outs = ["cnpg_postgresql_18_rootfs.tar"],
        cmd = """
set -euo pipefail
LAYOUT_RELATIVE="$(location @cloudnativepg_postgresql_18_linux_amd64//:cloudnativepg_postgresql_18_linux_amd64)"
if [[ "$${LAYOUT_RELATIVE}" != /* ]]; then
  LAYOUT="$$(pwd)/$${LAYOUT_RELATIVE}"
else
  LAYOUT="$${LAYOUT_RELATIVE}"
fi
# Normalize the path to remove any .. or .
LAYOUT="$$(cd "$$(dirname "$${LAYOUT}")" && pwd)/$$(basename "$${LAYOUT}")"
python3 "$(location //docker/images:export_rootfs_from_layout.py)" --layout "$${LAYOUT}" --output "$@"
""",
        visibility = ["//visibility:public"],
    )

    native.genrule(
        name = "glibc_runtime_layer",
        srcs = [
            "@debian_gcc_15_base_amd64_deb//file",
            "@debian_libgcc_s1_amd64_deb//file",
            "@debian_libc6_amd64_deb//file",
        ],
        outs = ["glibc_runtime_layer.tar"],
        tools = [
            "//docker/images:overlay_deb_packages.py",
        ],
        cmd = """
set -euo pipefail
OUT_DIR="$$(pwd)/$(@D)"
ROOT_DIR="$${OUT_DIR}/rootfs_glibc"
OUT_TAR="$$(pwd)/$@"
mkdir -p "$${ROOT_DIR}"
python3 "$(location //docker/images:overlay_deb_packages.py)" "$${ROOT_DIR}" \
  "$(location @debian_gcc_15_base_amd64_deb//file)" \
  "$(location @debian_libgcc_s1_amd64_deb//file)" \
  "$(location @debian_libc6_amd64_deb//file)"
tar -C "$${ROOT_DIR}" -cf "$${OUT_TAR}" .
""",
    )

    native.genrule(
        name = "timescaledb_extension_layer",
        srcs = [
            "@timescaledb_2_loader_postgresql_18_deb//file",
            "@timescaledb_2_postgresql_18_deb//file",
        ],
        outs = ["timescaledb_extension_layer.tar"],
        tools = [
            "//docker/images:overlay_deb_packages.py",
        ],
        cmd = """
set -euo pipefail
OUT_DIR="$$(pwd)/$(@D)"
OUT_TAR="$$(pwd)/$@"
ROOT_DIR="$${OUT_DIR}/timescaledb_debs"
rm -rf "$${ROOT_DIR}"
mkdir -p "$${ROOT_DIR}"
python3 "$(location //docker/images:overlay_deb_packages.py)" "$${ROOT_DIR}" \
  "$(location @timescaledb_2_loader_postgresql_18_deb//file)" \
  "$(location @timescaledb_2_postgresql_18_deb//file)"
tar -C "$${ROOT_DIR}" -cf "$${OUT_TAR}" .
""",
    )

    native.genrule(
        name = "age_extension_layer",
        srcs = [
            "@postgresql_18_age_amd64_deb//file",
        ],
        outs = ["age_extension_layer.tar"],
        tools = [
            "//docker/images:overlay_deb_packages.py",
        ],
        cmd = """
set -euo pipefail
OUT_DIR="$$(pwd)/$(@D)"
OUT_TAR="$$(pwd)/$@"
ROOT_DIR="$${OUT_DIR}/age_deb"
rm -rf "$${ROOT_DIR}"
mkdir -p "$${ROOT_DIR}"
python3 "$(location //docker/images:overlay_deb_packages.py)" "$${ROOT_DIR}" \
  "$(location @postgresql_18_age_amd64_deb//file)"
tar -C "$${ROOT_DIR}" -cf "$${OUT_TAR}" .
""",
    )

    native.genrule(
        name = "postgis_extension_layer",
        srcs = [
            "@postgresql_18_postgis_3_amd64_deb//file",
            "@postgresql_18_postgis_3_scripts_all_deb//file",
            "@postgresql_18_pgvector_amd64_deb//file",
            "@debian_libgeos_c1v5_amd64_deb//file",
            "@debian_libgeos3_11_1_amd64_deb//file",
            "@debian_libproj25_amd64_deb//file",
            "@debian_proj_data_all_deb//file",
            "@debian_libjson_c5_amd64_deb//file",
            "@debian_libprotobuf_c1_amd64_deb//file",
            "@debian_libtiff6_amd64_deb//file",
            "@debian_libcurl3_gnutls_amd64_deb//file",
            "@debian_libwebp7_amd64_deb//file",
            "@debian_liblerc4_amd64_deb//file",
            "@debian_libjbig0_amd64_deb//file",
            "@debian_libjpeg62_turbo_amd64_deb//file",
            "@debian_libdeflate0_amd64_deb//file",
            "@debian_libnghttp2_14_amd64_deb//file",
            "@debian_librtmp1_amd64_deb//file",
            "@debian_libssh2_1_amd64_deb//file",
            "@debian_libpsl5_amd64_deb//file",
            "@debian_libbrotli1_amd64_deb//file",
        ],
        outs = ["postgis_extension_layer.tar"],
        tools = [
            "//docker/images:overlay_deb_packages.py",
        ],
        cmd = """
set -euo pipefail
OUT_DIR="$$(pwd)/$(@D)"
OUT_TAR="$$(pwd)/$@"
ROOT_DIR="$${OUT_DIR}/rootfs_postgis"
rm -rf "$${ROOT_DIR}"
mkdir -p "$${ROOT_DIR}"
python3 "$(location //docker/images:overlay_deb_packages.py)" "$${ROOT_DIR}" \
  "$(location @postgresql_18_postgis_3_amd64_deb//file)" \
  "$(location @postgresql_18_postgis_3_scripts_all_deb//file)" \
  "$(location @postgresql_18_pgvector_amd64_deb//file)" \
  "$(location @debian_libgeos_c1v5_amd64_deb//file)" \
  "$(location @debian_libgeos3_11_1_amd64_deb//file)" \
  "$(location @debian_libproj25_amd64_deb//file)" \
  "$(location @debian_proj_data_all_deb//file)" \
  "$(location @debian_libjson_c5_amd64_deb//file)" \
  "$(location @debian_libprotobuf_c1_amd64_deb//file)" \
  "$(location @debian_libtiff6_amd64_deb//file)" \
  "$(location @debian_libcurl3_gnutls_amd64_deb//file)" \
  "$(location @debian_libwebp7_amd64_deb//file)" \
  "$(location @debian_liblerc4_amd64_deb//file)" \
  "$(location @debian_libjbig0_amd64_deb//file)" \
  "$(location @debian_libjpeg62_turbo_amd64_deb//file)" \
  "$(location @debian_libdeflate0_amd64_deb//file)" \
  "$(location @debian_libnghttp2_14_amd64_deb//file)" \
  "$(location @debian_librtmp1_amd64_deb//file)" \
  "$(location @debian_libssh2_1_amd64_deb//file)" \
  "$(location @debian_libpsl5_amd64_deb//file)" \
  "$(location @debian_libbrotli1_amd64_deb//file)"
EXT_DIR="$${ROOT_DIR}/usr/share/postgresql/18/extension"
ln -sf postgis-3.control "$${EXT_DIR}/postgis.control"
ln -sf postgis_raster-3.control "$${EXT_DIR}/postgis_raster.control"
ln -sf postgis_sfcgal-3.control "$${EXT_DIR}/postgis_sfcgal.control"
ln -sf postgis_topology-3.control "$${EXT_DIR}/postgis_topology.control"
ln -sf postgis_tiger_geocoder-3.control "$${EXT_DIR}/postgis_tiger_geocoder.control"
ln -sf address_standardizer-3.control "$${EXT_DIR}/address_standardizer.control"
tar -C "$${ROOT_DIR}" -cf "$${OUT_TAR}" .
""",
    )

    oci_image(
        name = "cnpg_image_amd64",
        base = "@cloudnativepg_postgresql_18_linux_amd64//:cloudnativepg_postgresql_18_linux_amd64",
        tars = [
            ":glibc_runtime_layer",
            ":timescaledb_extension_layer",
            ":age_extension_layer",
            ":postgis_extension_layer",
        ],
        labels = {
            "org.opencontainers.image.title": "serviceradar-cnpg",
        },
    )

    oci_load(
        name = "cnpg_image_amd64_tar",
        image = ":cnpg_image_amd64",
        repo_tags = ["registry.carverauto.dev/serviceradar/serviceradar-cnpg:local"],
    )
