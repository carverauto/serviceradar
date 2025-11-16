## 1. Custom CNPG image
- [x] 1.1 Create a Docker/Bazel image that extends the CloudNativePG Postgres 16.6 tag, compiles TimescaleDB (per https://docs.tigerdata.com/self-hosted/latest/install/installation-source/) and Apache AGE (per https://age.apache.org/age-manual/master/intro/setup.html) from the already-cloned sources, and sets `shared_preload_libraries=timescaledb,age`.
- [x] 1.2 Wire the new image into our build/publish tooling (Bazel target + ghcr tag) so CI can push updates and reuse the CNPG base image digest.

## 2. SPIRE CNPG deployment updates
- [x] 2.1 Update `k8s/demo/base/spire` CNPG manifests and the Helm `spire.postgres` template to use the custom image and preload parameters.
- [x] 2.2 Add init SQL (or `postInitApplicationSQL`) that creates the `timescaledb` and `age` extensions inside the `spire` database.
- [x] 2.3 Document the clean rebuild flow: tear down the existing CNPG cluster, redeploy it with the new image, re-apply the SPIRE manifests, and confirm the controller re-seeds registrations.

## 3. Validation
- [x] 3.1 Provide a `psql`/`kubectl exec` check that verifies `pg_extension` contains `timescaledb` and `age` after the rebuild.
- [x] 3.2 Capture SPIRE smoke test results (controller manager reconciles, workloads obtain SVIDs) before closing the change.

## 4. Build tooling fixes
- [x] 4.1 Vendor the `crane` binary under `third_party/binaries` and wire `cnpg_postgresql_16_6_rootfs_tar` to that target so Bzlmod is no longer trying to alias the `rules_oci++oci+oci_crane_*` repositories.
- [x] 4.2 Replace the raw `tar -xf` extraction for the CNPG rootfs with a whiteout-aware helper so the TimescaleDB and AGE genrules can reliably unpack the exported root filesystem without "Cannot open: File exists" errors.
