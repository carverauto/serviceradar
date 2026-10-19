# Device inventory rollup write cost

Availability changes previously subtracted and re-added every inventory
contribution. Each device update executed eight counter upserts and four
dimension-cleanup deletes, even when total, type and vendor counts stayed
the same. An 11,000-device tick therefore executed 132,000 counter-maintenance
statements.

The batch rollup migration aggregates old and new contributions from PostgreSQL
transition tables. Each statement writes each changed counter once; zero net
changes write nothing. Dimension cleanup checks only a changed key.

An upsert fires separate UPDATE and INSERT statement triggers, so sorting keys
inside one trigger cannot order counter locks across both. Each trigger with a
net change therefore takes one transaction-scoped advisory lock before its first
counter write. Writers that change counts serialize until commit; the previous
trigger already serialized every insert, delete and availability change on the
total counter row. Statements with no net change take no lock. A 500-device
availability batch updates at most two status counters, with no
total/type/vendor writes or cleanup deletes. The 22-batch tick needs at most 44
counter writes plus 66 aggregate reads of the statement's changed rows.

Counts remain transactional. The existing active-device definition
(`deleted_at IS NULL AND source_retired_at IS NULL`), null availability,
normalized dimensions, bulk-write bypass and explicit refresh are preserved.
No backfill or fleet scan runs during migration. Rollback reinstalls the
previous row trigger using its retained function and helper.

## Isolated synthetic measurement

Measured on 2026-10-19 against a disposable database on the shared CNPG test
fixture. The supporting schema was intentionally minimal, with the real
historical rollup migrations and their source-retirement triggers. It was not
a full application schema or the ServiceRadar Atlas acceptance workload.

The invented population contained 11,000 devices, eight type values and four
vendor values. Each of three ticks flipped availability and updated an invented
IPv6 address in 22 sequential 500-row statements. Each statement ran with
`EXPLAIN (ANALYZE, BUFFERS, WAL, FORMAT JSON)`; reported database times are sums
across those statements. The same database was measured before and after applying
the actual migration through Ecto's migration runner.

| Median per tick | Row trigger | Batch triggers |
| --- | ---: | ---: |
| Database execution | 4,564.540 ms | 195.813 ms |
| Rollup trigger execution | 4,428.326 ms | 55.659 ms |
| Trigger calls | 11,000 | 22 |
| Client wall time | 5,457.286 ms | 1,096.720 ms |

These are three-sample observations on shared infrastructure, not tail-latency
guarantees. Client times include network and workstation scheduling. The
measurement predates the advisory lock and was not repeated; the lock adds one
acquisition per changing trigger and serializes concurrent changing writers,
which this sequential probe does not exercise. It isolates this trigger's cost;
it does not establish five-second churn cadence with 1.1 million devices,
concurrent bitmap refreshes and 100 map viewers. That requires rerunning the
compact and sparse Atlas acceptance suites.

## Regression boundary

`DeviceInventoryRollupDbTest` observes real counter writes and cleanup statements,
and compares maintained counts with independent counts of canonical devices.
Its availability assertion failed against the old trigger with the redundant
total/type/vendor operations. It covers one-row and 500-row batches, cancelling
changes, no-ops, mixed insert/upsert, reclassification, source retirement,
soft-delete/restore, hard delete, bulk bypass/refresh, transaction rollback,
migration rollback/reapply, and an upsert racing a concurrent insert on separate
connections, which deadlocked before the advisory lock. Tests and profiling
data are synthetic.
