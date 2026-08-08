## 1. Proposal
- [x] 1.1 Validate with `openspec validate add-delta-metrics-lakehouse --strict`.

## 2. Decision-gate measurement (do this first)
- [ ] 2.1 Capture per-agent steady-state metric output for a `process_limit=25` agent over a defined window and sampling interval (the number missing from the 50k sizing); record rows/sec/agent and bytes/sec/agent.
- [ ] 2.2 Recompute the central raw-row projection from the measured per-agent rate for the near-term (~2,500-agent) and 50k targets, with and without edge rollups, and record the corrected target rows/sec.
- [ ] 2.3 Decision gate: if the corrected per-tenant raw rate fits a tuned CNPG window plus CAGGs, scope this change to long-retention raw only; if not, the Delta raw tier is required for serving raw history. Record the decision in design.md.

## 3. Delta write path
- [ ] 3.1 Add `rust/metrics-delta-writer` consuming the metrics JetStream durable; decode the `MetricBatch` protobuf and batch-write raw points to a Delta table via delta-rs.
- [ ] 3.2 Partition the Delta table by tenant / source / time bucket / `hash(series)` so DuckDB can prune files; choose batch size/flush interval to keep file counts and small-file pressure manageable.
- [ ] 3.3 Add object-store config per tenant (bucket/prefix), credentials via the existing secret path, and a dead-letter/replay path for write failures.
- [ ] 3.4 Benchmark Delta write throughput against captured fixtures; prove it meets the task 2.2 corrected target with headroom.

## 4. CNPG retention re-tiering
- [ ] 4.1 Reduce raw `timeseries_metrics` retention to a recent window sized for live graphing and sub-6h drill-down; validate chunk interval/size against the measured row rate.
- [ ] 4.2 Keep all CAGG rollups, metadata, alerts, findings, and capacity forecasts in CNPG unchanged.
- [ ] 4.3 Verify capacity forecasting and existing dashboards still resolve from CNPG rollups after the raw window shrinks.

## 5. DuckDB query path + SRQL routing
- [ ] 5.1 Stand up a DuckDB query path (embedded or per-tenant sidecar) with the `delta` and `httpfs` extensions over the lake and the `postgres` extension attached to CNPG.
- [ ] 5.2 Add the metrics backend abstraction to SRQL at the per-entity codegen seam; route recent/aggregate metric windows to CNPG and long-range/raw windows to DuckDB-over-Delta. Non-metric entities unchanged.
- [ ] 5.3 Support federated long-range graphing: a single SRQL query spanning recent CNPG rows and long-term Delta history returns one coherent result set.
- [ ] 5.4 Prove DuckDB-over-Delta query latency for the raw/long-range query shapes the UI and capacity/backtesting paths need; record latencies.

## 6. Maintenance + migration
- [ ] 6.1 Add a per-tenant Delta maintenance job: compaction, snapshot/manifest expiry, retention.
- [ ] 6.2 Dual-write/parity: run Delta write alongside CNPG raw; compare query results for raw-dependent queries until parity is proven. CNPG raw is not reduced until parity holds.
- [ ] 6.3 Document the per-tenant object-store + DuckDB topology under the instance-per-tenant SaaS model (dedicated CNPG + NATS + object-store prefix per customer).

## 7. Tests and delivery
- [ ] 7.1 Round-trip test: points written through the Delta writer read back identically through DuckDB and through SRQL.
- [ ] 7.2 SRQL routing test: window threshold selects CNPG vs DuckDB-over-Delta correctly, including the federated span case.
- [ ] 7.3 Summarize the corrected sizing, the write/read benchmarks, and the parity result in the PR.
- [ ] 7.4 Open a Forgejo PR against `staging`.
