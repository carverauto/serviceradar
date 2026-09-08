## Why
- The SRQL query engine uses PostgreSQL `ILIKE` for case-insensitive text matching on fields like `hostname`, `ip`, `mac`, `device_id`, `service_name`, and many others across entity types (devices, device_updates, otel_metrics, timeseries_metrics, etc.).
- Standard B-Tree indexes cannot accelerate `ILIKE` queries, especially with leading wildcards (e.g., `%server%`). These queries result in full table scans which degrade performance as tables grow.
- The `pg_trgm` extension provides trigram-based GIN indexes that can efficiently support `ILIKE` and `LIKE` patterns including leading wildcards.
- This change was identified during a code review (GitHub issue #2047) and is a targeted performance optimization with minimal risk.

## What Changes
- Enable the `pg_trgm` extension in the CNPG database via a new migration.
- Create GIN trigram indexes on the most frequently searched text columns in `unified_devices` (hostname, ip) and optionally other high-traffic tables.
- Document the performance trade-offs (slightly slower writes, faster wildcard searches) and index maintenance considerations.

## Scope
### In Scope
- Adding a CNPG migration to `CREATE EXTENSION IF NOT EXISTS pg_trgm`.
- Creating GIN indexes using `gin_trgm_ops` on `unified_devices.hostname` and `unified_devices.ip` as the primary search targets.
- Evaluating and optionally indexing additional columns in `device_updates`, `services`, and `otel_spans` if they are common ILIKE targets.
- Updating the CNPG spec documentation to note the pg_trgm dependency.

### Out of Scope
- Changing the SRQL query engine code (no Rust changes needed; PostgreSQL will automatically use the GIN indexes for ILIKE queries).
- Indexing every text column; we will start with the highest-impact columns and expand based on query patterns.
- Normalized lowercase column approach (e.g., `hostname_lower`); we prefer the trigram approach for its flexibility with arbitrary patterns.

## Impact
- **Affected specs**: `cnpg` (extension dependency)
- **Affected code**: `pkg/db/cnpg/migrations/` (new migration file)
- **Performance**: Write operations on indexed columns will be marginally slower due to GIN index maintenance; read operations with `ILIKE` will be significantly faster.
- **Storage**: GIN trigram indexes are larger than B-Tree indexes; expect ~1-3x the column data size per index.
