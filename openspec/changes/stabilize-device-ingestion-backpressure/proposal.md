# Change: Stabilize device ingestion when AGE graph backpressures the registry

## Why
Core is logging AGE graph queue timeouts (`queue_wait_secs` ~120s, `context deadline exceeded`) and large non-canonical skips during stats aggregation while the inventory is stuck around 20k devices instead of the expected ~50k faker load. The stats cache shows CNPG reporting only ~3.3k devices while the in-memory registry holds ~16k, and ICMP capabilities for `k8s-agent` have disappeared. AGE writes are serialized and waited on synchronously in `ProcessBatchDeviceUpdates`, so the graph backlog stalls ingest traffic and lets registry/CNPG counts drift.

## What Changes
- Decouple registry ingest from AGE graph execution with bounded, async graph dispatch so device updates cannot stall on the graph queue; add fast-fail/backoff when the graph path is unhealthy.
- Add parity diagnostics between CNPG and registry (stats cache + logs/metrics/alerts) with tolerances for faker-scale loads, and surface why records are skipped as non-canonical.
- Ensure service-device capability updates (ICMP for `k8s-agent`, etc.) persist even under graph backpressure, with a replay path for any dropped capability or graph batches.

## Impact
- Affected specs: device-inventory, device-relationship-graph
- Affected code: pkg/core/stats_aggregator.go, pkg/registry/age_graph_writer.go, pkg/registry/registry.go, pkg/core/metrics.go, observability/alert wiring
