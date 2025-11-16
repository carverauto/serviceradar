## Why
- The demo SPIRE deployment depends on a CNPG cluster that currently runs the stock CloudNativePG Postgres image without any additional extensions.
- New ServiceRadar features require TimescaleDB for time-series rollups and Apache AGE for property-graph queries, but our existing CNPG install cannot load either extension.
- Apache AGE and TimescaleDB both officially support PostgreSQL 16 (Timescale recommends 16.6), so we need to standardize on that version and compile both extensions from source to stay on supported releases.
- Building and pinning our own CNPG-compatible image with the required extensions keeps the SPIRE datastore aligned with the rest of the data platform and gives us headroom to reuse the cluster for telemetry experiments without re-provisioning.

## What Changes
- Publish a custom CNPG-ready Postgres 16.6 image (based on the CloudNativePG operator tag) that compiles TimescaleDB and Apache AGE from source per the upstream docs, preloads the extensions, and exposes them through `shared_preload_libraries`.
- Vendor the `crane` CLI inside the repo (instead of relying on the `@oci_crane_*` repositories from `rules_oci`) so Bazel can export the CNPG rootfs without tripping Bzlmod's ban on aliasing `rules_oci++oci+…` names, and harden the extraction path so OCI whiteouts are applied correctly when compiling the extensions.
- Update the SPIRE CNPG manifests (demo kustomize + Helm chart) to consume the new image, configure TimescaleDB/AGE shared preload parameters, and ensure the init SQL enables both extensions in the `spire` database.
- Document the clean rebuild process: delete the legacy CNPG cluster, deploy the new image, re-initialize SPIRE (controller resources + database schema), and verify SVID issuance works without requiring any data backup.

## Impact
- SPIRE downtime during the CNPG cluster rebuild; agents cannot issue new certificates until the server reconnects to Postgres.
- Requires publishing and maintaining a container image in our registry; CI must build and push on demand.
- Adds TimescaleDB and Apache AGE binaries (compiled for PostgreSQL 16.6) to the SPIRE database pods, slightly increasing their disk footprint and memory requirements.
