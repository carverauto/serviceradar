# Change: Improve CNPG slow-query observability in demo

## Why

GitHub issue #2994 reports recurring slow queries in web-ng pages in the `demo` namespace. Today we have `pg_stat_statements` enabled, but we do not have a consistent operational workflow and telemetry baseline for fast detection, triage, and regression tracking of slow CNPG queries.

We need immediate observability improvements that are low-risk and compatible with the current CNPG PostgreSQL 18 deployment.

## What Changes

- Strengthen CNPG slow-query observability in `demo` using existing safe primitives (`pg_stat_statements`, query duration logging, and standardized triage queries).
- Standardize runbooks and documentation for collecting and correlating slow-query evidence from CNPG and ServiceRadar telemetry.
- Add low-cardinality slow-query metrics derivation from existing telemetry/log sources for ongoing trend visibility and alerting.
- Standardize documentation/config references on the current in-cluster collector service (`serviceradar-log-collector`) and protocol/port mapping.

## Impact

- Affected specs: `cnpg`
- Affected code:
  - `helm/serviceradar/values.yaml` and CNPG templates/manifests (`postgresql.parameters`, logging thresholds, optional toggles)
  - `k8s/demo/base/spire/cnpg-cluster.yaml` (demo CNPG runtime parameters)
  - OTEL/log-collector configuration and dashboards/queries for metric derivation
  - `docs/docs/cnpg-monitoring.md`, `docs/docs/otel.md` (runbook and endpoint correctness)
- Operational impact:
  - Improves time-to-diagnosis for slow CNPG queries in demo.
  - Adds consistent incident triage steps and metrics for regression detection.
