# edge_sweep_projected_rows: insert and prune cost

Issue: https://github.com/carverauto/serviceradar/issues/7069

## What the table is

`platform.edge_sweep_projected_rows` holds one row per `(kind, batch_index, element_index)`
coordinate of each primary `SweepObservationBatchV1` delivery, written by
`ServiceRadar.Edge.Projectors.SweepObservation.project_domain_rows/5` with
`ON CONFLICT DO NOTHING` against the primary key `(network_scope_id, row_key)`, where
`row_key = sha256(len || semantic_digest || ordinal)`.

No production code reads it. Exactly-once is decided earlier, in the same transaction, by
`event_ledger` and `edge_sweep_batch_slots`; this table is only written when the delivery
is already primary. Its readers are the retention worker and the Go edge-record
integration tests (`integration_tests/edge_record/vertical_slice_test.go`), which use it as
the "no duplicate domain rows under redelivery" artifact introduced by the first vertical
slice (`20260910120000_create_edge_record_ledger.exs`).

## Measured on demo (2026-11-26)

Read-only: `pg_stat_statements` and `pg_stat_user_tables` on the primary, one
`EXPLAIN (ANALYZE, BUFFERS)` of the prune's candidate SELECT on the hot standby, TID-range
samples of the heap on the standby.

- About 61M rows, heap 7.4 GB, primary key 5.9 GB (about 96 bytes per entry, about 70%
  leaf density, the normal steady state of random-key inserts), `event_id` index 0.4 GB.
- Retention horizon: `retention_horizon_seconds/2` resolves to 30 days plus 4500 s (the
  spool retry horizon dominates). The oldest row was 21.4 days old and sat on heap page 0;
  `inserted_at` correlation 0.99995. The issue's "about 20 days retained" is the table's
  age, not the horizon: the table is still filling and will settle near 30 days, about
  1.4 times today's size.

### Prune

- `n_tup_del = 0` and `pg_stat_statements.rows = 0` over 390 calls: the prune has never
  deleted a row. Nothing is old enough yet.
- Each call is a full sequential scan that finds nothing: the standby EXPLAIN read 941k
  blocks (the whole heap), removed 61.4M rows by the `inserted_at` filter, never executed
  the batch-slot hash or the epoch guard, 15 s. On the primary: mean 5.0 s, 569k blocks
  read per call (the heap size averaged over its growth).
- The NOT EXISTS guards are not the cost. Once rows do expire, the last batch of every
  run is short, so without an index on `inserted_at` each hourly run would still end in
  a full scan.

### Insert

- 26.6k calls, 61.4M rows (about 2300 per call), mean 487 ms; 63.4M blocks read (1.03 per
  row), 60.8M dirtied (0.99 per row), 254 GB of WAL (4.1 KB per row).
- The primary key's `idx_scan` equals the inserted row count: every row descends to a
  random leaf of a 5.9 GB index (shared_buffers 1 GB). With 15-minute checkpoints and about
  30 batches an hour, almost every dirtied leaf is a first touch after a checkpoint, so it
  writes a full-page image. There are no triggers and no foreign keys; the heap append and
  the `event_id` index (one key per batch) are cheap.

## Scratch benchmark (srql-fixtures, 6.9M pre-loaded rows, 8 batches of 2300 after a checkpoint)

| Layout | ms | blocks read | dirtied | WAL FPI | WAL |
| --- | --- | --- | --- | --- | --- |
| current (PK on random `row_key`) | 1175 | 17567 | 17412 | 16877 | 106.7 MB |
| current + B-tree on `inserted_at` | 600 | 17531 | 17406 | 16829 | 107.5 MB |
| PK `(network_scope_id, event_id, kind, batch_index, element_index)` | 212 | 24 | 624 | 33 | 7.1 MB |

The `inserted_at` index adds under 1% WAL and no measurable dirtied pages (right-edge
inserts). Its size is about 21 bytes per row (about 1.3 GB at today's size). With it, the
prune's no-candidate case reads 3 blocks; a batch of 5000 expired rows reads about 130 index
blocks; a generic plan stays on the index because the query orders by `inserted_at`.

## Done in this change

1. `20261126070000_index_edge_sweep_projected_rows_inserted_at.exs`: concurrent B-tree on
   `inserted_at`. An interrupted build leaves an invalid index under that name; this
   migration drops it and rebuilds it, so a retry does not record a name the planner
   never uses.
2. The projected-rows prune orders its candidates by `inserted_at`, so it walks the index
   oldest first and stops at the cutoff.

Not changed: the guards and the horizon. Rows older than the cutoff whose batch slot is
still guarded (draining epoch, open scheduled slot) are re-read through the index each
batch; that range is bounded by the expired range, not the table.

`edge_delivery_slots` (0.34 GB) and `event_ledger` (0.27 GB) prunes have the same
full-scan shape at about 26k blocks per call. They are small today; the same index plus
ORDER BY applies if they grow.

## Insert cost: decided, outside this change

The insert cost is the random primary key. Decision on
[#7069](https://github.com/carverauto/serviceradar/issues/7069) (operator, 2026-11-26):
verify, then stop writing the table. This change is the prune index. Stopping the writer
is the next change.

After this index is on demo, confirm nothing else depends on the table: dedup, replay,
and exactly-once paths, the Go vertical-slice tests, specs and docs, and ledger coverage.
If that holds, stop `ServiceRadar.Edge.Projectors.SweepObservation` from writing it and
drop the table after one retention horizon (30 days). Exactly-once is already
`event_ledger` plus `edge_sweep_batch_slots`, and no production code reads the table.
Stopping the writer removes the 61M rows, 13 GB, and about 250 GB of WAL from its first
22 days. The Go vertical-slice test currently uses these rows as the "no duplicate domain
rows" artifact; that assertion moves to the real sweep tables, or to the batch slot's
`projected_row_count`, before the writer stops. `DROP TABLE` is then enough: the table
holds nothing exactly-once still needs.

Rejected for now:

- **Clustered re-key** to `(network_scope_id, event_id, kind, batch_index, element_index)`
  (an `ordinal` column, or those three columns), with `row_key` kept as a plain column.
  A batch then touches a handful of adjacent leaves: about 28x fewer dirtied pages and
  15x less WAL in the benchmark. The `event_id` index becomes redundant. Swapping the
  primary key of a 60-90M row table is a rebuild; the cheap path would be a new table
  written by the projector, with the old one left to age out under retention.
- **Time partitioning with partition drop.** A partition can be dropped only when none of
  its rows is guarded, the unique key must include the partition key (so `ON CONFLICT`
  on `row_key` alone no longer works), and it does not fix the random-key insert cost
  by itself.

Rejected earlier: BRIN on `inserted_at` (#7063; summaries only widen after delete plus
space reuse), a narrower hash in `row_key` (any random key has the same one-leaf-per-row
cost).

## Verify on demo after rollout

- The index exists and is valid: `\d platform.edge_sweep_projected_rows`.
- `pg_stat_statements` for the projected-rows DELETE: mean time in milliseconds and
  `shared_blks_read` per call in the tens, not 500k+, while nothing has expired.
- Insert statement: `shared_blks_dirtied` and `wal_bytes` per call unchanged within noise.
- From about 2026-12-04, when the oldest rows pass 30 days: `n_tup_del` on the table rises
  and the worker's `deleted_sweep_projected_rows` log field is non-zero, and the heap
  stops growing.
