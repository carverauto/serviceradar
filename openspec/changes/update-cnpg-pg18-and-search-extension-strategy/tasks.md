## 1. CNPG Build Inputs

- [x] 1.1 Update Bazel external OCI pull for CloudNativePG Postgres base image from `16.6-bookworm` to a PostgreSQL 18 tag.
- [x] 1.2 Update PG development package artifact references from PG16 to PG18 equivalents in `MODULE.bazel`.
- [x] 1.3 Update PostGIS/pgvector package artifact references from `postgresql-16-*` to `postgresql-18-*`.
- [x] 1.4 Update Apache AGE source artifact from 1.6.0 to 1.7.0 and verify checksum.

## 2. CNPG Image Assembly

- [x] 2.1 Update `docker/images/BUILD.bazel` CNPG extension-layer rules to use PG18 rootfs paths (`/usr/lib/postgresql/18/...`, `/usr/share/postgresql/18/...`).
- [x] 2.2 Update CNPG base image alias names and references (`cnpg_postgresql_*`, `serviceradar_cnpg_*`) to PG18 naming.
- [x] 2.3 Build `//docker/images:cnpg_image_amd64` successfully and verify extension control/sql artifacts are present for PG18.

## 3. Cluster Manifests and Helm

- [x] 3.1 Update demo CNPG cluster image tag in `k8s/demo/base/spire/cnpg-cluster.yaml` to PG18 custom image.
- [x] 3.2 Update SRQL fixture CNPG image tag in `k8s/srql-fixtures/cnpg-cluster.yaml` to PG18 custom image.
- [x] 3.3 Update Helm defaults in `helm/serviceradar/values.yaml` for `spire.postgres.imageName` to PG18 custom image.
- [x] 3.4 Verify extension bootstrap SQL and preload libraries remain correct (`timescaledb`, `age`, `postgis`, `vector`, `pg_stat_statements`).

## 4. Upgrade Safety Validation

- [ ] 4.1 Document and run staging preflight for extension compatibility: TimescaleDB, AGE, PostGIS, pgvector, pg_trgm, pg_stat_statements.
- [ ] 4.2 Validate AGE graph operations on upgraded cluster (`ag_catalog.create_graph`, cypher read/write smoke tests).
- [ ] 4.3 Validate TimescaleDB hypertable and continuous aggregate operations post-upgrade.
- [x] 4.4 Capture rollback instructions and operational checkpoints.

## 5. Search Extension Strategy

- [x] 5.1 Add docs section defining ParadeDB (`pg_search`) as production BM25 path.
- [x] 5.2 Add docs section marking `pg_textsearch` as experimental/non-production until GA and current limitations are removed.
- [x] 5.3 Add a compatibility checklist for any future switch from ParadeDB to `pg_textsearch`.
