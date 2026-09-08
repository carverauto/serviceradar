## 1. Baseline CNPG Slow-Query Observability (Demo)

- [x] 1.1 Confirm and document current `pg_stat_statements` coverage and top-query inspection workflow in `demo`.
- [x] 1.2 Add/verify CNPG query-duration logging thresholds suitable for slow-query triage without excessive log volume.
- [x] 1.3 Add demo runbook steps for capturing and correlating slow-query evidence from CNPG and OTEL/log telemetry.

## 2. Slow-Query Metrics Derivation

- [x] 2.1 Define low-cardinality metric schema for slow-query monitoring (counts, latency buckets, errors).
- [x] 2.2 Implement metric derivation from existing telemetry/log data sources in demo.
- [x] 2.3 Validate end-to-end visibility with test queries and confirm dashboard/query outputs.

## 3. Docs and Operationalization

- [x] 3.1 Update docs/config references to the correct collector service and protocol/port usage in Kubernetes demo.
- [x] 3.2 Add rollback/tuning instructions for query logging thresholds.
- [x] 3.3 Define initial slow-query alert thresholds and dashboard panels for ongoing monitoring.
