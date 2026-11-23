## 1. CNPG Schema Migration
- [x] 1.1 Create `elixir/serviceradar_core/priv/repo/migrations/20261123171500_create_horizon_tables.exs` with `platform.horizon_outages`, `platform.horizon_bgp_events`, `platform.horizon_bgp_zombies`, and `platform.horizon_path_hops`.
- [x] 1.2 Add TimescaleDB hypertable conversion and targeted indexes for time, prefix, ASN, status, and identifier columns.

## 2. EventWriter Projection
- [x] 2.1 Implement `ServiceRadar.EventWriter.Processors.HorizonProjection` for `horizon.outage`, `horizon.bgp_anomaly`, `horizon.bgp_watchlist`, and `horizon.bgp_zombie` OCSF events with fail-open error handling.
- [x] 2.2 Wire `HorizonProjection.project_rows/1` into `ServiceRadar.EventWriter.Processors.Events`.
- [x] 2.3 Add unit tests in `elixir/serviceradar_core/test/serviceradar/event_writer/horizon_projection_test.exs`.

## 3. Rust SRQL Entities and Access Control
- [x] 3.1 Add Diesel table definitions to `rust/srql/src/schema.rs` and row models to `rust/srql/src/models/horizon.rs`.
- [x] 3.2 Add `Entity` variants and parser aliases in `rust/srql/src/parser/{ast.rs,entity.rs}`.
- [x] 3.3 Implement `horizon_outages.rs`, `horizon_bgp.rs`, `horizon_zombies.rs`, and `horizon_paths.rs` under `rust/srql/src/query/` with unit tests covering parsing, SQL generation, bind-count parity, and filters.
- [x] 3.4 Wire all four entities into `query/mod.rs`, `query/engine.rs`, `query/translate.rs`, `query/viz/{horizon.rs,mod.rs}`, and `elixir/web-ng/lib/serviceradar_web_ng/srql/entity_access.ex`.

## 4. Verification
- [x] 4.1 Run `openspec validate add-horizon-srql-entities --strict`.
- [x] 4.2 Run `cargo fmt --all -- --check`, `cargo clippy --all-targets -- -D warnings`, and `cargo test` in `rust/srql`.
- [x] 4.3 Run `mix format --check-formatted` and `mix test test/serviceradar/event_writer/horizon_projection_test.exs` in `elixir/serviceradar_core`.
