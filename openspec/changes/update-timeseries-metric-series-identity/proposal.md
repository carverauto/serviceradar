# Change: Widen timeseries metric identity to per-series keys

## Why
`timeseries_metrics` currently treats `(timestamp, gateway_id, metric_name)` as the unique identity for upserts. That is too narrow for SNMP, ICMP, and plugin metrics because multiple devices or interfaces can legitimately emit the same metric name at the same timestamp through the same gateway. Live demo logs already show `ON CONFLICT DO UPDATE command cannot affect row a second time` during SNMP ingest, which means the storage contract is dropping or rejecting valid metrics.

## What Changes
- Add a stable `series_key` field to `platform.timeseries_metrics` and make per-sample uniqueness use `(timestamp, gateway_id, series_key)` instead of `(timestamp, gateway_id, metric_name)`.
- Define `series_key` composition so distinct device/interface/check/plugin series do not collide while exact duplicate samples still upsert cleanly.
- Update Elixir metric ingestors and the Ash resource identity to generate and use `series_key` consistently.
- Add migration/backfill logic so existing rows receive deterministic `series_key` values before the unique constraint is switched.
- Add regression coverage for SNMP/interface collisions and any other ingest paths that share the timeseries pipeline.

## Impact
- Affected specs: `cnpg`, `observability-signals`
- Affected code: `elixir/serviceradar_core/lib/serviceradar/observability/*.ex`, `elixir/serviceradar_core/lib/serviceradar/observability/timeseries_metric.ex`, Timescale/CNPG migrations, and any readers that assume the old uniqueness contract
