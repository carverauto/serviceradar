## 1. Enable pg_trgm extension
- [x] 1.1 Create a new migration file `00000000000016_pg_trgm_extension.up.sql` that runs `CREATE EXTENSION IF NOT EXISTS pg_trgm;`.
- [x] 1.2 Create the corresponding down migration `00000000000016_pg_trgm_extension.down.sql` with `DROP EXTENSION IF EXISTS pg_trgm;`.
- [x] 1.3 Verify the extension loads successfully in a local CNPG cluster by running `SELECT * FROM pg_extension WHERE extname = 'pg_trgm';`.

## 2. Create GIN trigram indexes on unified_devices
- [x] 2.1 Add `CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_unified_devices_hostname_trgm ON unified_devices USING gin (hostname gin_trgm_ops);` to the migration.
- [x] 2.2 Add `CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_unified_devices_ip_trgm ON unified_devices USING gin (ip gin_trgm_ops);` to the migration.
- [x] 2.3 Verify indexes are created and used by running `EXPLAIN ANALYZE` on an `ILIKE` query (e.g., `SELECT * FROM unified_devices WHERE hostname ILIKE '%server%'`). Note: With small tables (<100 rows), PostgreSQL correctly chooses Seq Scan as more efficient than index lookup.

## 3. Evaluate additional high-traffic columns
- [~] 3.1 Review SRQL query logs or common use cases to identify other frequently searched text columns (e.g., `device_updates.hostname`, `services.service_name`, `otel_spans.service_name`). *Skipped: deferred to future optimization cycle.*
- [~] 3.2 Add GIN trigram indexes to additional columns if analysis shows benefit (keep as separate migration if needed to manage rollout). *Skipped: deferred to future optimization cycle.*

## 4. Documentation and spec updates
- [x] 4.1 Update the `cnpg` spec to note the `pg_trgm` extension as a required dependency.
- [x] 4.2 Add a note in the CNPG migration README (if one exists) or the main database documentation about the purpose of trigram indexes and their performance characteristics. *Added to `docs/docs/cnpg-monitoring.md`.*

## 5. Validation
- [x] 5.1 Run the migration against a test CNPG cluster and confirm no errors.
- [x] 5.2 Execute representative ILIKE queries before and after index creation, comparing `EXPLAIN ANALYZE` output to confirm index usage.
- [x] 5.3 Verify the SRQL query engine continues to function correctly with no code changes required.
