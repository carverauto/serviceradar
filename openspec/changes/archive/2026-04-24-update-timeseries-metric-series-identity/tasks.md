## 1. Schema
- [x] 1.1 Add a `series_key` column to `platform.timeseries_metrics` and backfill deterministic values for existing rows.
- [x] 1.2 Replace the old unique identity/constraint on `(timestamp, gateway_id, metric_name)` with the new `(timestamp, gateway_id, series_key)` contract.
- [x] 1.3 Verify any dependent rollups/views/resources continue to work with the widened identity.

## 2. Ingestion
- [x] 2.1 Update `TimeseriesMetric` Ash identity to use `series_key`.
- [x] 2.2 Update SNMP, ICMP, and plugin metrics ingestors to compute `series_key` and dedupe only exact duplicate samples.
- [x] 2.3 Keep exact replay/upsert behavior idempotent for repeated identical samples.

## 3. Validation
- [x] 3.1 Add regression tests for multi-interface SNMP batches sharing the same timestamp/gateway/metric name.
- [x] 3.2 Add regression tests for other timeseries ingestors that share the common identity path.
- [x] 3.3 Validate with targeted tests/lint and confirm the bulk create no longer raises `cardinality_violation` for valid mixed-series batches.
