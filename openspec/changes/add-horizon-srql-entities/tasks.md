## 1. StarRocks DDL and Warehouse Wiring
- [x] 1.1 Create `elixir/serviceradar_core/priv/starrocks/0044_horizon_tables.sql` with daily-partitioned Primary Key tables `horizon_outages`, `horizon_bgp_events`, `horizon_bgp_zombies` (`partition_live_number = 30`), and `horizon_path_hops` (`partition_live_number = 14`).
- [x] 1.2 Register all four datasets in `StarRocks.Destination`, `StarRocks.Rows`, and `StarRocks.Readers` with explicit `{:error, :starrocks_required}` when StarRocks is disabled.

## 2. EventWriter StarRocks Projection
- [x] 2.1 Implement StarRocks-only `ServiceRadar.EventWriter.Processors.HorizonProjection` using exact `plugins/horizon-feed/src/ocsf.rs` unmapped keys and per-table fail-open error isolation.
- [x] 2.2 Wire `HorizonProjection.project_rows/1` into `ServiceRadar.EventWriter.Processors.Events`.
- [x] 2.3 Add unit tests in `elixir/serviceradar_core/test/serviceradar/event_writer/horizon_projection_test.exs` covering projection, per-table fail-open, `Rows.encode/2`, and `Readers.mode_for/1`.

## 3. Rust StarRocks-Only SRQL Entities and Access Control
- [x] 3.1 Add canonical `Entity` variants (`horizon_outages`, `horizon_bgp`, `horizon_zombies`, `horizon_paths`) in `rust/srql/src/parser/{ast.rs,entity.rs}` without extra aliases.
- [x] 3.2 Implement `rust/srql/src/query/starrocks/horizon.rs` and wire into `starrocks.rs`, `engine.rs`, `translate.rs`, `viz/{horizon.rs,mod.rs}`, and `elixir/web-ng/lib/serviceradar_web_ng/srql/entity_access.ex`.
- [x] 3.3 Add Rust unit tests covering StarRocks SQL translation, filters, ordering, removed-alias rejection, and non-StarRocks rejection.

## 4. Verification
- [x] 4.1 Run `openspec validate add-horizon-srql-entities --strict`.
- [x] 4.2 Run `cargo fmt -p srql -- --check`, `cargo clippy --all-targets -- -D warnings`, and `cargo test` in `rust/srql`.
- [x] 4.3 Run `mix format --check-formatted` and `mix test --no-start test/serviceradar/event_writer/horizon_projection_test.exs` in `elixir/serviceradar_core`.
