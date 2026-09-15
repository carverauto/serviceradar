"""serviceradar-cnpg-analytics OCI image (pg_duckdb analytics head).

CloudNativePG PostgreSQL 18 (the same base as the primary, UID 26) plus a
pg_duckdb extension layer lifted from the digest-pinned official
pgduckdb/pgduckdb image, plus bookworm libstdc++ and libcurl (DuckDB is C++
and speaks S3 over curl). TimescaleDB,
AGE, and PostGIS are not installed — pg_duckdb calling standard_planner() next
to TimescaleDB is a SIGSEGV (duckdb/pg_duckdb#845, #963).

pg_duckdb is NOT compiled from source here and is NOT added to the primary
CNPG image. Runtime posture (C-collation initdb, duckdb.* GUCs, emptyDir
spill) is owned by the Helm analytics-head component.

The extension layer genrule ABI-checks pg_duckdb.so against the CNPG sysroot
the same way the Timescale/AGE layers do. Digest pin bumps of @pgduckdb_18
must also pass //docker/images:cnpg_analytics_boot_smoke (CREATE EXTENSION +
Parquet round-trip).
"""

load("@rules_oci//oci:defs.bzl", "oci_image", "oci_load")

# Keep in sync with the @pgduckdb_18 pull in MODULE.bazel and the static tag in
# image_inventory.bzl.
CNPG_ANALYTICS_PGDUCKDB_REF = "docker.io/pgduckdb/pgduckdb:18-v1.1.1"

def declare_cnpg_analytics_image_amd64():
    """Declare the analytics-head image on the CNPG PostgreSQL 18 base."""

    native.genrule(
        name = "cnpg_analytics_runtime_layer",
        srcs = [
            "@debian_libstdcpp6_amd64_deb//file",
            "@debian_libcurl4_amd64_deb//file",
            "@debian_libcurl3_gnutls_amd64_deb//file",
            "@debian_libnghttp2_14_amd64_deb//file",
            "@debian_librtmp1_amd64_deb//file",
            "@debian_libssh2_1_amd64_deb//file",
            "@debian_libpsl5_amd64_deb//file",
            "@debian_libbrotli1_amd64_deb//file",
        ],
        outs = ["cnpg_analytics_runtime_layer.tar"],
        tools = [
            "//docker/images:overlay_deb_packages.py",
        ],
        cmd = """
set -euo pipefail
OUT_DIR="$$(pwd)/$(@D)"
ROOT_DIR="$${OUT_DIR}/rootfs_analytics_runtime"
OUT_TAR="$$(pwd)/$@"
rm -rf "$${ROOT_DIR}"
mkdir -p "$${ROOT_DIR}"
python3 "$(location //docker/images:overlay_deb_packages.py)" "$${ROOT_DIR}" \\
  "$(location @debian_libstdcpp6_amd64_deb//file)" \\
  "$(location @debian_libcurl4_amd64_deb//file)" \\
  "$(location @debian_libcurl3_gnutls_amd64_deb//file)" \\
  "$(location @debian_libnghttp2_14_amd64_deb//file)" \\
  "$(location @debian_librtmp1_amd64_deb//file)" \\
  "$(location @debian_libssh2_1_amd64_deb//file)" \\
  "$(location @debian_libpsl5_amd64_deb//file)" \\
  "$(location @debian_libbrotli1_amd64_deb//file)"
find "$${ROOT_DIR}" -exec touch -h -t 200001010000.00 {} + 2>/dev/null || \\
  find "$${ROOT_DIR}" -exec touch -t 200001010000.00 {} +
tar -C "$${ROOT_DIR}" -cf "$${OUT_TAR}" .
""",
    )

    native.genrule(
        name = "pg_duckdb_extension_layer",
        srcs = [
            "@pgduckdb_18_linux_amd64//:pgduckdb_18_linux_amd64",
            ":cnpg_postgresql_18_rootfs_tar",
            "@debian_libstdcpp6_amd64_deb//file",
            "@debian_libcurl4_amd64_deb//file",
            "@debian_libcurl3_gnutls_amd64_deb//file",
            "@debian_libnghttp2_14_amd64_deb//file",
            "@debian_librtmp1_amd64_deb//file",
            "@debian_libssh2_1_amd64_deb//file",
            "@debian_libpsl5_amd64_deb//file",
            "@debian_libbrotli1_amd64_deb//file",
        ],
        outs = ["pg_duckdb_extension_layer.tar"],
        tools = [
            "//docker/images:check_extension_abi.py",
            "//docker/images:export_rootfs_from_layout.py",
            "//docker/images:extract_pg_duckdb_layer.py",
            "//docker/images:extract_rootfs.py",
            "//docker/images:overlay_deb_packages.py",
        ],
        cmd = """
set -euo pipefail
OUT_DIR="$$(pwd)/$(@D)"
OUT_TAR="$$(pwd)/$@"
PGDUCK_ROOT="$${OUT_DIR}/rootfs_pgduckdb"
SYSROOT="$${OUT_DIR}/sysroot_cnpg"
INSTALL="$${OUT_DIR}/install_pg_duckdb"
rm -rf "$${PGDUCK_ROOT}" "$${SYSROOT}" "$${INSTALL}"
mkdir -p "$${PGDUCK_ROOT}" "$${SYSROOT}" "$${INSTALL}"

LAYOUT_RELATIVE="$(location @pgduckdb_18_linux_amd64//:pgduckdb_18_linux_amd64)"
if [[ "$${LAYOUT_RELATIVE}" != /* ]]; then
  LAYOUT="$$(pwd)/$${LAYOUT_RELATIVE}"
else
  LAYOUT="$${LAYOUT_RELATIVE}"
fi
LAYOUT="$$(cd "$$(dirname "$${LAYOUT}")" && pwd)/$$(basename "$${LAYOUT}")"
python3 "$(location //docker/images:export_rootfs_from_layout.py)" \
  --layout "$${LAYOUT}" --output "$${OUT_DIR}/pgduckdb_rootfs.tar"
python3 "$(location //docker/images:extract_rootfs.py)" \
  "$${OUT_DIR}/pgduckdb_rootfs.tar" "$${PGDUCK_ROOT}"
python3 "$(location //docker/images:extract_pg_duckdb_layer.py)" \
  --src "$${PGDUCK_ROOT}" --dest "$${INSTALL}"

python3 "$(location //docker/images:extract_rootfs.py)" \
  "$(location :cnpg_postgresql_18_rootfs_tar)" "$${SYSROOT}"
python3 "$(location //docker/images:overlay_deb_packages.py)" "$${SYSROOT}" \
  "$(location @debian_libstdcpp6_amd64_deb//file)" \
  "$(location @debian_libcurl4_amd64_deb//file)" \
  "$(location @debian_libcurl3_gnutls_amd64_deb//file)" \
  "$(location @debian_libnghttp2_14_amd64_deb//file)" \
  "$(location @debian_librtmp1_amd64_deb//file)" \
  "$(location @debian_libssh2_1_amd64_deb//file)" \
  "$(location @debian_libpsl5_amd64_deb//file)" \
  "$(location @debian_libbrotli1_amd64_deb//file)"

SO_PATH="$$(find "$${INSTALL}" -name pg_duckdb.so -print | head -n1)"
CONTROL_PATH="$$(find "$${INSTALL}" -name pg_duckdb.control -print | head -n1)"
if [[ -z "$${SO_PATH}" || -z "$${CONTROL_PATH}" ]]; then
  echo "pg_duckdb.so or pg_duckdb.control missing from the analytics layer" >&2
  find "$${INSTALL}" -print >&2
  exit 1
fi
echo "Checking pg_duckdb glibc floor against the CNPG runtime base:"
python3 "$(location //docker/images:check_extension_abi.py)" \
  --sysroot "$${SYSROOT}" \
  "$$(dirname "$${SO_PATH}")"
if find "$${INSTALL}" \\( -iname '*timescaledb*' -o -iname '*postgis*' \\) | grep -q .; then
  echo "analytics layer must not contain TimescaleDB or PostGIS files:" >&2
  find "$${INSTALL}" \\( -iname '*timescaledb*' -o -iname '*postgis*' \\) >&2
  exit 1
fi

find "$${INSTALL}" -exec touch -h -t 200001010000.00 {} + 2>/dev/null || \
  find "$${INSTALL}" -exec touch -t 200001010000.00 {} +
tar -C "$${INSTALL}" -cf "$${OUT_TAR}" .
""",
    )

    native.genrule(
        name = "cnpg_analytics_marker_layer",
        outs = ["cnpg_analytics_marker_layer.tar"],
        cmd = """
set -euo pipefail
OUT_DIR="$$(pwd)/$(@D)"
ROOT_DIR="$${OUT_DIR}/rootfs_cnpg_analytics"
rm -rf "$${ROOT_DIR}"
mkdir -p "$${ROOT_DIR}/etc/serviceradar"
{
  echo "image=serviceradar-cnpg-analytics"
  echo "base=registry.carverauto.dev/mirror/cloudnative-pg/postgresql"
  echo "pg_duckdb_source=%s"
  echo "role=analytics-head"
} > "$${ROOT_DIR}/etc/serviceradar/cnpg-analytics.release"
find "$${ROOT_DIR}" -exec touch -h -t 200001010000.00 {} + 2>/dev/null || \
  find "$${ROOT_DIR}" -exec touch -t 200001010000.00 {} +
tar -C "$${ROOT_DIR}" -cf "$$(pwd)/$@" .
""" % CNPG_ANALYTICS_PGDUCKDB_REF,
    )

    oci_image(
        name = "cnpg_analytics_image_amd64",
        base = "@cloudnativepg_postgresql_18_linux_amd64//:cloudnativepg_postgresql_18_linux_amd64",
        tars = [
            ":glibc_runtime_layer",
            ":cnpg_analytics_runtime_layer",
            ":pg_duckdb_extension_layer",
            ":cnpg_analytics_marker_layer",
        ],
        labels = {
            "org.opencontainers.image.title": "serviceradar-cnpg-analytics",
            "org.opencontainers.image.base.name": "registry.carverauto.dev/mirror/cloudnative-pg/postgresql",
        },
    )

    oci_load(
        name = "cnpg_analytics_image_amd64_tar",
        image = ":cnpg_analytics_image_amd64",
        repo_tags = ["registry.carverauto.dev/serviceradar/serviceradar-cnpg-analytics:local"],
    )
