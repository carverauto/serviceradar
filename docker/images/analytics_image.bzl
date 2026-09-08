"""serviceradar-cnpg-analytics OCI image (cold-tier analytics head).

Deliberately thin: the official pgduckdb/pgduckdb image (PostgreSQL 18 +
pg_duckdb, MIT, digest-pinned in MODULE.bazel as @pgduckdb_18) is republished
under our registry with a provenance marker layer and OCI labels. pg_duckdb is
NOT compiled from source here, and no TimescaleDB/AGE/PostGIS is added — the
analytics head must never load them (see openspec add-tiered-telemetry-offload
D1/D12). Runtime posture (C-collation initdb, duckdb.* GUCs, memory/spill
sizing) is owned by the Helm analytics-head component, not this image.

Digest pin bumps are gated by scripts/ci/cold-analytics-image-smoke.sh.
"""

load("@rules_oci//oci:defs.bzl", "oci_image", "oci_load")

# Keep in sync with the @pgduckdb_18 pull in MODULE.bazel and the static tag in
# image_inventory.bzl.
CNPG_ANALYTICS_BASE_REF = "docker.io/pgduckdb/pgduckdb:18-v1.1.1"

def declare_cnpg_analytics_image_amd64():
    """Declare the analytics-head image on top of the pinned pgduckdb base."""

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
  echo "base=%s"
  echo "role=cold-tier-analytics-head"
} > "$${ROOT_DIR}/etc/serviceradar/cnpg-analytics.release"
tar -C "$${ROOT_DIR}" -cf "$$(pwd)/$@" .
""" % CNPG_ANALYTICS_BASE_REF,
    )

    oci_image(
        name = "cnpg_analytics_image_amd64",
        base = "@pgduckdb_18_linux_amd64//:pgduckdb_18_linux_amd64",
        tars = [
            ":cnpg_analytics_marker_layer",
        ],
        labels = {
            "org.opencontainers.image.title": "serviceradar-cnpg-analytics",
            "org.opencontainers.image.base.name": CNPG_ANALYTICS_BASE_REF,
        },
    )

    oci_load(
        name = "cnpg_analytics_image_amd64_tar",
        image = ":cnpg_analytics_image_amd64",
        repo_tags = ["registry.carverauto.dev/serviceradar/serviceradar-cnpg-analytics:local"],
    )
