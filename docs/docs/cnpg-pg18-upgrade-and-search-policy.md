---
title: CNPG PostgreSQL 18 Upgrade and Search Policy
---

# CNPG PostgreSQL 18 Upgrade and Search Policy

This runbook defines the PostgreSQL 18 upgrade path for ServiceRadar CNPG clusters and the supported BM25 search extension strategy.

## Target Versions

- PostgreSQL: `18.x` (CNPG upstream `18-bookworm` base)
- TimescaleDB: `2.24.0`
- Apache AGE: `1.7.x`
- PostGIS: `3.6.2`
- pgvector: `0.8.2`

## Preflight Checklist

Run these checks against staging before rollout:

1. Verify extension availability and installed versions:

```sql
SELECT name, default_version
FROM pg_available_extensions
WHERE name IN ('timescaledb', 'age', 'postgis', 'vector', 'pg_trgm', 'pg_stat_statements')
ORDER BY name;

SELECT extname, extversion
FROM pg_extension
WHERE extname IN ('timescaledb', 'age', 'postgis', 'vector', 'pg_trgm', 'pg_stat_statements')
ORDER BY extname;
```

2. Verify app-critical schemas/tables exist in `platform`.
3. Confirm backups/PITR are healthy before image rollout.
4. Record current image tag and extension versions for rollback evidence.

## Build and Publish the PG18 CNPG Image

Build and push from the current commit:

```bash
bazel build //docker/images:cnpg_image_amd64
bazel run //docker/images:cnpg_image_amd64_push
```

Tag and publish as `ghcr.io/carverauto/serviceradar-cnpg:18.3.0-sr2` (or your release tag), then update cluster manifests/Helm values.

## Post-Upgrade Validation

### AGE Smoke Test

```sql
CREATE EXTENSION IF NOT EXISTS age;
LOAD 'age';
SET search_path = ag_catalog, "$user", public;

SELECT ag_catalog.create_graph('upgrade_smoke_graph');
SELECT * FROM cypher('upgrade_smoke_graph', $$
  CREATE (:Node {name: 'pg18-smoke'})
$$) AS (n agtype);
SELECT * FROM cypher('upgrade_smoke_graph', $$
  MATCH (n:Node {name: 'pg18-smoke'}) RETURN n
$$) AS (n agtype);
SELECT ag_catalog.drop_graph('upgrade_smoke_graph', true);
```

### TimescaleDB Smoke Test

```sql
CREATE TABLE IF NOT EXISTS platform.pg18_smoke_metrics (
  ts timestamptz NOT NULL,
  host text NOT NULL,
  value double precision NOT NULL
);

SELECT create_hypertable('platform.pg18_smoke_metrics', 'ts', if_not_exists => true);
INSERT INTO platform.pg18_smoke_metrics (ts, host, value)
VALUES (now() - interval '5 minutes', 'smoke-host', 1.0), (now(), 'smoke-host', 2.0);

CREATE MATERIALIZED VIEW IF NOT EXISTS platform.pg18_smoke_metrics_5m
WITH (timescaledb.continuous) AS
SELECT time_bucket('5 minutes', ts) AS bucket, host, avg(value) AS avg_value
FROM platform.pg18_smoke_metrics
GROUP BY 1, 2
WITH NO DATA;

CALL refresh_continuous_aggregate('platform.pg18_smoke_metrics_5m', now() - interval '1 hour', now());
SELECT * FROM platform.pg18_smoke_metrics_5m ORDER BY bucket DESC LIMIT 5;

DROP MATERIALIZED VIEW IF EXISTS platform.pg18_smoke_metrics_5m;
DROP TABLE IF EXISTS platform.pg18_smoke_metrics;
```

## Rollback Checkpoints

- Keep prior image tag (`16.6.0-sr5`) available.
- Preserve a pre-upgrade backup/snapshot for point-in-time recovery.
- If post-upgrade validation fails:
  1. Scale write-heavy services down.
  2. Roll CNPG image back to last known good tag.
  3. Restore from backup if catalog extension state is inconsistent.
  4. Re-run extension validation SQL and app smoke tests before reopening traffic.

## BM25 Search Extension Policy

### Production Path

Use ParadeDB (`pg_search`) as the production BM25 extension path.

### Experimental Path

`pg_textsearch` is experimental/non-production until GA readiness and required limitations (including compressed data behavior) are resolved.

## Future Migration Checklist (ParadeDB -> pg_textsearch)

Before any production switch:

1. Validate functional parity on ranking/query semantics for existing SRQL search use cases.
2. Validate behavior on compressed and uncompressed Timescale data.
3. Verify index build/maintenance overhead at production ingest rates.
4. Run dual-write or shadow-query comparison in staging.
5. Define a rollback path that keeps ParadeDB indexes and query path available until sign-off.
6. Update docs/specs and operational ownership before rollout.
