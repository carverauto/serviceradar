## ADDED Requirements

### Requirement: OTel service catalog table
CNPG SHALL provide `platform.otel_service_catalog` with one row per OTel `service_name`, holding `logs_last_seen_at`, `traces_last_seen_at`, `metrics_last_seen_at`, `first_seen_at` and `last_seen_at`. The table SHALL be created only by an Elixir migration in the `platform` schema.

The table SHALL have a trigram GIN index on `service_name` and a btree index on `last_seen_at DESC`. It is control-plane inventory, holds no telemetry counts or samples, and SHALL remain in CNPG when StarRocks is enabled.

#### Scenario: Substring search uses the trigram index
- **GIVEN** the catalog holds tens of thousands of entries
- **WHEN** `SELECT service_name FROM platform.otel_service_catalog WHERE service_name ILIKE '%pay%' ORDER BY last_seen_at DESC LIMIT 50` runs
- **THEN** the plan SHALL use the trigram index rather than a sequential scan

#### Scenario: Catalog present with StarRocks enabled
- **GIVEN** StarRocks is enabled as the telemetry store
- **WHEN** the platform schema is migrated
- **THEN** `platform.otel_service_catalog` SHALL exist in CNPG

### Requirement: Trace summaries service-set index
CNPG SHALL provide a GIN index on `platform.otel_trace_summaries.service_set`, created concurrently so trace summary maintenance is not blocked, to serve participating-service filters.

#### Scenario: Participating-service filter uses the index
- **WHEN** `SELECT trace_id FROM platform.otel_trace_summaries WHERE service_set @> ARRAY['checkout'] ORDER BY timestamp DESC LIMIT 100` runs on a populated table
- **THEN** the plan SHALL use the `service_set` GIN index
