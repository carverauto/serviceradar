# Change: Upgrade CNPG to PostgreSQL 18 and define search extension strategy

## Why

As of March 3, 2026, ServiceRadar still runs CNPG on PostgreSQL 16.6 (`ghcr.io/carverauto/serviceradar-cnpg:16.6.0-sr5`) while upstream TimescaleDB and CNPG now support PostgreSQL 18. We also need Apache AGE 1.7 for PG18 compatibility.

At the same time, we need to choose a Postgres-native BM25/full-text path:
- `pg_textsearch` aligns with Timescale, but is still development/preview and currently excludes compressed data support.
- ParadeDB is currently the more production-ready BM25 path.

Without an explicit decision and upgrade path, we risk extension mismatch, failed cluster upgrades, and fragmented search implementation.

## What Changes

- Upgrade ServiceRadar CNPG build and deployment defaults from PostgreSQL 16.6 to PostgreSQL 18.
- Upgrade Apache AGE source from 1.6.0 to 1.7.0 in the custom CNPG image build.
- Update Bazel external package inputs and CNPG image assembly rules from PG16-specific package names/paths to PG18 equivalents.
- Update demo manifests, Helm defaults, and SRQL fixture manifests to reference the PG18 CNPG image tag.
- Add a compatibility preflight and validation runbook for all enabled extensions (TimescaleDB, AGE, PostGIS, pgvector, pg_trgm, pg_stat_statements).
- Define search extension strategy:
  - Use ParadeDB (`pg_search`) as the production BM25 extension path.
  - Keep `pg_textsearch` explicitly non-production/experimental until GA and required limitations are resolved.

## Impact

- Affected specs: `cnpg`
- Affected code:
  - `MODULE.bazel` (CNPG base image pull + PG package artifacts + AGE source)
  - `docker/images/BUILD.bazel` (CNPG extension layer build paths and PG version-specific install locations)
  - `k8s/demo/base/spire/cnpg-cluster.yaml`
  - `k8s/srql-fixtures/cnpg-cluster.yaml`
  - `helm/serviceradar/values.yaml`
  - `docs/docs/**` CNPG/upgrade docs
- Operational impact:
  - Requires controlled CNPG major upgrade rollout (staging first, then production).
  - Requires validation of extension behavior after upgrade.
  - Introduces a single production BM25 path to reduce operational ambiguity.
