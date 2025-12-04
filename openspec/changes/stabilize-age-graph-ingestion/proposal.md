# Change: Stabilize AGE graph ingestion under contention

## Why
Core in the demo namespace is emitting AGE write failures (`Entity failed to be updated: 3` / SQLSTATE XX000) and statement timeouts while registering pollers, which maps to Postgres `TM_Updated` lock conflicts in AGE’s `cypher_set` path. The registry/topology writers and the age-backfill job all fire MERGE batches in parallel with no retry/backpressure, so overlapping writes lose batches and block until statement_timeout.

## What Changes
- Funnel AGE graph writes through a bounded worker/queue with chunking so MERGE batches do not run concurrently against the same graph and stay under CNPG statement timeouts.
- Add targeted retry/backoff for transient AGE errors (TM_Updated/XX000 and statement_timeout) plus metrics/logging for queued/failed batches so operators can spot contention.
- Coordinate age-backfill with live ingestion (shared queue or mutex/flag) and document the demo runbook so rebuilds do not clobber live writes.

## Impact
- Affected specs: device-relationship-graph
- Affected code: pkg/registry/age_graph_writer.go, pkg/core/discovery.go, cmd/tools/age-backfill, docs/docs/runbooks/age-graph-readiness.md, CNPG/AGE config (statement_timeout, worker tuning)
