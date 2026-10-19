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
fixture, with the final advisory lock included. The supporting schema was
intentionally minimal: the real historical rollup migrations, their
source-retirement triggers and the active-IP uniqueness index. It was not a
full application schema or the ServiceRadar Atlas acceptance workload.

The invented population contained 11,000 devices, eight type values and four
vendor values. Each of three ticks flipped availability and updated an invented
IPv6 address in 22 sequential 500-row statements. Each statement ran with
`EXPLAIN (ANALYZE, BUFFERS, WAL, FORMAT JSON)`; reported database times are sums
across those statements. The same database was measured before and after applying
the actual migration through Ecto's migration runner.

| Median per tick | Row trigger | Batch triggers |
| --- | ---: | ---: |
| Database execution | 41,257.963 ms | 467.757 ms |
| Rollup trigger execution | 41,056.048 ms | 83.154 ms |
| Trigger calls | 11,000 | 22 |
| Client wall time | 43,625.631 ms | 3,495.091 ms |

The three batch-trigger samples were 65.067, 83.154 and 96.296 ms. Shared
fixture variability is substantial: an earlier three-sample run of the same
probe measured a 4,428.326 ms median row-trigger time. These are three-sample
sequential observations, not throughput or tail-latency guarantees, and client
times include network and workstation scheduling. The probe does not exercise
concurrent changing writers, which the advisory lock serializes.

## Compact Atlas scale run

The compact Atlas server scale suite passed at the final trigger commit
(BuildBuddy invocation `6990cdc2-a734-449a-beb8-495e61a584c3`) and is compared
with the earlier compact run `7302a932-f361-42a6-8dea-35a7c9aaeffb`. Both used
a synthetic population of 1.1 million devices and 2.2 million addresses, 100
viewers (10 slow), two replicas, and 100 churn ticks of 11,000 devices against
the same 5,000 ms cadence target.

| Per-tick device write | Before | After |
| --- | ---: | ---: |
| Mean | 10,382.83 ms | 938.85 ms |
| p50 | 10,295 ms | 885 ms |
| p95 | 13,310 ms | 1,347 ms |
| Max | 13,705 ms | 1,908 ms |
| Writes under 5,000 ms | 0/100 | 100/100 |

Mean write time was about 91% lower. The runs were not contemporaneous and
shared infrastructure, so the ratio is indicative only. Other measures did not
improve:

| Run-wide measure | Before | After |
| --- | ---: | ---: |
| Combined elapsed | 1,748,951 ms | 1,542,050 ms |
| Convergence | 90,988 ms | 152,838 ms |
| Facet query p95 | 164 ms | 272 ms |
| HTTP 503 among 100 facet queries | 14 | 20 |

This does not establish five-second end-to-end churn cadence or a universal
performance improvement; the wider convergence remains unresolved. The server
suite excludes browser/GPU rendering and layout persistence, and the sparse
ordinal suite has not been rerun for this change.

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
