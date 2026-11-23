## 1. CNPG Schema Migration & Retention
- [x] 1.1 Create `elixir/serviceradar_core/priv/repo/migrations/20261123171500_create_horizon_tables.exs` with `platform.horizon_outages`, `platform.horizon_bgp_events`, `platform.horizon_bgp_zombies`, and `platform.horizon_path_hops`.
- [x] 1.2 Add TimescaleDB hypertable conversion (1-day chunk interval) and targeted indexes for time, prefix, ASN, status, and identifier columns.
- [x] 1.3 Register all four Horizon hypertables in `ServiceRadar.Observability.DataRetentionWorker` (`horizon_retention_days`, default 14 days; `horizon_chunk_interval_hours`, default 24 hours; capped by `cnpg_telemetry_default_days`) and wire runtime config in `serviceradar_core` and `serviceradar_core_elx`.

## 2. EventWriter Projection
- [x] 2.1 Implement `ServiceRadar.EventWriter.Processors.HorizonProjection` for `horizon.outage`, `horizon.bgp_anomaly`, `horizon.bgp_watchlist`, and `horizon.bgp_zombie` OCSF events with independent per-table fail-open error handling.
- [x] 2.2 Wire `HorizonProjection.project_rows/1` into the CNPG write path of `ServiceRadar.EventWriter.Processors.Events` and skip CNPG projection when `Destination.warehouse?(:events)` is true.
- [x] 2.3 Add unit tests in `elixir/serviceradar_core/test/serviceradar/event_writer/horizon_projection_test.exs` and retention config coverage in `elixir/serviceradar_core/test/serviceradar/observability/data_retention_runtime_config_test.exs`.
- Note (Out of Scope): Dedicated JetStream `EventWriter` ingestion for `platform.horizon_path_hops` is deferred to a follow-up change; this change provisions the `horizon_path_hops` table, retention reconciliation, and `in:horizon_paths` SRQL contract only.

## 3. Rust SRQL Entities and Access Control
- [x] 3.1 Add Diesel table definitions to `rust/srql/src/schema.rs` and row models to `rust/srql/src/models/horizon.rs`.
- [x] 3.2 Add `Entity` variants and parser aliases in `rust/srql/src/parser/{ast.rs,entity.rs}`.
- [x] 3.3 Implement `horizon_outages.rs`, `horizon_bgp.rs`, `horizon_zombies.rs`, and `horizon_paths.rs` under `rust/srql/src/query/` with unit tests covering parsing, SQL generation, bind-count parity, and filters.
- [x] 3.4 Wire all four entities into `query/mod.rs`, `query/engine.rs`, `query/translate.rs`, `query/viz/{horizon.rs,mod.rs}`, and `elixir/web-ng/lib/serviceradar_web_ng/srql/entity_access.ex`.

## 4. Verification
- [x] 4.1 Run `openspec validate add-horizon-srql-entities --strict`.
- [x] 4.2 Run `cargo fmt --all -- --check`, `cargo clippy --all-targets -- -D warnings`, and `cargo test` in `rust/srql`.
- [x] 4.3 Run `mix format --check-formatted` and `mix test test/serviceradar/event_writer/horizon_projection_test.exs` in `elixir/serviceradar_core`.
