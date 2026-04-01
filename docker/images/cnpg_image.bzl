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
            ":cnpg_postgresql_18_rootfs_tar",
            "@postgresql_server_dev_18_deb//file",
            "@debian_bison_amd64_deb//file",
            "@debian_flex_amd64_deb//file",
            "@debian_libpq_dev_amd64_deb//file",
            "@debian_gcc_15_base_amd64_deb//file",
            "@debian_libgcc_s1_amd64_deb//file",
            "@debian_libc6_amd64_deb//file",
            "//database/timescaledb:source_tree",
            "//docker/images:pg_config_wrapper.sh",
        ],
        outs = ["timescaledb_extension_layer.tar"],
        tools = [
            "//docker/images:extract_rootfs.py",
            "//docker/images:overlay_deb_packages.py",
            "//docker/images:pg_config_rewrite.py",
            "@cmake_linux_amd64_prebuilt//:cmake_bin",
            "@cmake_linux_amd64_prebuilt//:cmake_share",
        ],
        cmd = """
set -euo pipefail
OUT_DIR="$$(pwd)/$(@D)"
OUT_TAR="$$(pwd)/$@"
ROOT_DIR="$${OUT_DIR}/rootfs_timescaledb"
python3 "$(location //docker/images:extract_rootfs.py)" "$(location :cnpg_postgresql_18_rootfs_tar)" "$${ROOT_DIR}"
python3 "$(location //docker/images:overlay_deb_packages.py)" "$${ROOT_DIR}" \
  "$(location @postgresql_server_dev_18_deb//file)" \
  "$(location @debian_bison_amd64_deb//file)" \
  "$(location @debian_flex_amd64_deb//file)" \
  "$(location @debian_libpq_dev_amd64_deb//file)" \
  "$(location @debian_gcc_15_base_amd64_deb//file)" \
  "$(location @debian_libgcc_s1_amd64_deb//file)" \
  "$(location @debian_libc6_amd64_deb//file)"
sed -i 's|^CLANG = .*|CLANG = clang|' "$${ROOT_DIR}/usr/lib/postgresql/18/lib/pgxs/src/Makefile.global"
sed -i 's|^with_llvm\t= .*|with_llvm\t= no|' "$${ROOT_DIR}/usr/lib/postgresql/18/lib/pgxs/src/Makefile.global"

SRC_TREE="$$(pwd)/$(execpath //database/timescaledb:source_tree)"
echo "Copying TimescaleDB sources from $${SRC_TREE}"
if [[ -d "$${OUT_DIR}/timescaledb" ]]; then
  chmod -R u+w "$${OUT_DIR}/timescaledb"
  rm -rf "$${OUT_DIR}/timescaledb"
fi
mkdir -p "$${OUT_DIR}/timescaledb"
cp -R "$${SRC_TREE}/." "$${OUT_DIR}/timescaledb"
chmod -R u+w "$${OUT_DIR}/timescaledb"
cp "$(location //docker/images:pg_config_wrapper.sh)" "$${OUT_DIR}/pg_config_wrapper_ts.sh"
chmod +x "$${OUT_DIR}/pg_config_wrapper_ts.sh"
cp "$(location //docker/images:pg_config_rewrite.py)" "$${OUT_DIR}/pg_config_rewrite.py"

CMAKE_RELATIVE="$(location @cmake_linux_amd64_prebuilt//:cmake_bin)"
if [[ "$${CMAKE_RELATIVE}" != /* ]]; then
  CMAKE_BIN="$$(pwd)/$${CMAKE_RELATIVE}"
else
  CMAKE_BIN="$${CMAKE_RELATIVE}"
fi
# Don't use readlink -f - cmake needs the original path to find its modules
chmod +x "$${CMAKE_BIN}"
CMAKE_DIR="$$(dirname "$${CMAKE_BIN}")"
mkdir -p "$${OUT_DIR}/bin"
ln -sf "$${CMAKE_BIN}" "$${OUT_DIR}/bin/cmake"
export CMAKE="$${CMAKE_BIN}"
export CNPG_ROOT="$${ROOT_DIR}"
export CNPG_REAL_PG_CONFIG="$${ROOT_DIR}/usr/lib/postgresql/18/bin/pg_config"
export PATH="$${OUT_DIR}/bin:$${CMAKE_DIR}:$${ROOT_DIR}/usr/lib/postgresql/18/bin:$${ROOT_DIR}/usr/bin:/usr/bin:/bin"
export PKG_CONFIG_PATH="$${ROOT_DIR}/usr/lib/pkgconfig:$${ROOT_DIR}/usr/lib/x86_64-linux-gnu/pkgconfig"
cd "$${OUT_DIR}/timescaledb"
BUILD_FORCE_REMOVE=true ./bootstrap -DREGRESS_CHECKS=OFF -DPROJECT_INSTALL_METHOD=docker -DCMAKE_BUILD_TYPE=RelWithDebInfo -DPG_CONFIG="$${OUT_DIR}/pg_config_wrapper_ts.sh"
cd build
make -j4
mkdir -p "$${OUT_DIR}/install"
make DESTDIR="$${OUT_DIR}/install_ts" install
INSTALL_PREFIX="$${OUT_DIR}/install_ts$${CNPG_ROOT}"
if [[ ! -d "$${INSTALL_PREFIX}" ]]; then
  echo "Timescale install prefix $${INSTALL_PREFIX} not found" >&2
  exit 1
fi
tar -C "$${INSTALL_PREFIX}" -cf "$${OUT_TAR}" .
""",
    )

    native.genrule(
        name = "age_extension_layer",
        srcs = [
            ":cnpg_postgresql_18_rootfs_tar",
            "@postgresql_server_dev_18_deb//file",
            "@debian_libpq_dev_amd64_deb//file",
            "@debian_gcc_15_base_amd64_deb//file",
            "@debian_libgcc_s1_amd64_deb//file",
            "@debian_libc6_amd64_deb//file",
            "//database/age:source_tree",
            "//docker/images:pg_config_wrapper.sh",
        ],
        outs = ["age_extension_layer.tar"],
        tools = [
            "//docker/images:extract_rootfs.py",
            "//docker/images:overlay_deb_packages.py",
            "//docker/images:pg_config_rewrite.py",
        ],
        cmd = """
set -euo pipefail
REPO_ROOT="$$(pwd)"
OUT_DIR="$$(pwd)/$(@D)"
OUT_TAR="$$(pwd)/$@"
ROOT_DIR="$${OUT_DIR}/rootfs_age"
python3 "$(location //docker/images:extract_rootfs.py)" "$(location :cnpg_postgresql_18_rootfs_tar)" "$${ROOT_DIR}"
python3 "$(location //docker/images:overlay_deb_packages.py)" "$${ROOT_DIR}" \
  "$(location @postgresql_server_dev_18_deb//file)" \
  "$(location @debian_libpq_dev_amd64_deb//file)" \
  "$(location @debian_gcc_15_base_amd64_deb//file)" \
  "$(location @debian_libgcc_s1_amd64_deb//file)" \
  "$(location @debian_libc6_amd64_deb//file)"
sed -i 's|^CLANG = .*|CLANG = clang|' "$${ROOT_DIR}/usr/lib/postgresql/18/lib/pgxs/src/Makefile.global"
sed -i 's|^with_llvm\t= .*|with_llvm\t= no|' "$${ROOT_DIR}/usr/lib/postgresql/18/lib/pgxs/src/Makefile.global"

AGE_TREE="$$(pwd)/$(execpath //database/age:source_tree)"
if [[ -d "$${OUT_DIR}/age" ]]; then
  chmod -R u+w "$${OUT_DIR}/age"
  rm -rf "$${OUT_DIR}/age"
fi
mkdir -p "$${OUT_DIR}/age"
cp -R "$${AGE_TREE}/." "$${OUT_DIR}/age"
chmod -R u+w "$${OUT_DIR}/age"

cp "$${REPO_ROOT}/$(location //docker/images:pg_config_wrapper.sh)" "$${OUT_DIR}/pg_config_wrapper_age.sh"
chmod +x "$${OUT_DIR}/pg_config_wrapper_age.sh"
cp "$${REPO_ROOT}/$(location //docker/images:pg_config_rewrite.py)" "$${OUT_DIR}/pg_config_rewrite.py"

for tool in flex bison gperf; do
  if ! command -v "$${tool}" >/dev/null 2>&1; then
    echo "Missing required build tool: $${tool} (expected in the RBE executor image or host toolchain)" >&2
    exit 1
  fi
done

export CNPG_ROOT="$${ROOT_DIR}"
export CNPG_REAL_PG_CONFIG="$${ROOT_DIR}/usr/lib/postgresql/18/bin/pg_config"
export PATH="$${ROOT_DIR}/usr/lib/postgresql/18/bin:$${ROOT_DIR}/usr/bin:/usr/bin:/bin:$${PATH:-}"
export PKG_CONFIG_PATH="$${ROOT_DIR}/usr/lib/pkgconfig:$${ROOT_DIR}/usr/lib/x86_64-linux-gnu/pkgconfig:$${PKG_CONFIG_PATH:-}"
cd "$${OUT_DIR}/age"
make PG_CONFIG="$${OUT_DIR}/pg_config_wrapper_age.sh" FLEX=flex LEX=flex BISON=bison YACC="bison -y" -j4
mkdir -p "$${OUT_DIR}/install_age"
make PG_CONFIG="$${OUT_DIR}/pg_config_wrapper_age.sh" FLEX=flex LEX=flex BISON=bison YACC="bison -y" DESTDIR="$${OUT_DIR}/install_age" install
INSTALL_PREFIX="$${OUT_DIR}/install_age$${CNPG_ROOT}"
if [[ ! -d "$${INSTALL_PREFIX}" ]]; then
  echo "AGE install prefix $${INSTALL_PREFIX} not found" >&2
  exit 1
fi
tar -C "$${INSTALL_PREFIX}" -cf "$${OUT_TAR}" .
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
