# edge_sweep_projected_rows: insert and prune cost

Issue: https://github.com/carverauto/serviceradar/issues/7069

## What the table is

`platform.edge_sweep_projected_rows` held one row per `(kind, batch_index, element_index)`
coordinate of each primary `SweepObservationBatchV1` delivery, keyed by
`(network_scope_id, row_key)` with `row_key = sha256(len || semantic_digest || ordinal)` and
inserted `ON CONFLICT DO NOTHING`. Since the change described under "Writer stopped" below,
nothing writes or prunes the table, and a migration in the next PR drops it once this
change is deployed everywhere.

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
inserts). Its size is about 21 bytes per row (about 1.3 GB at the 2026-11-26 size). With it,
the prune's no-candidate case read 3 blocks; a batch of 5000 expired rows read about 130
index blocks; a generic plan stayed on the index because the query ordered by `inserted_at`.
That prune no longer runs; see "Writer stopped".

## Prune index (#7076)

This index landed before the writer and the prune stopped. It stays until the drop in the
next PR.

1. `20261126070000_index_edge_sweep_projected_rows_inserted_at.exs`: concurrent B-tree on
   `inserted_at`. An interrupted build leaves an invalid index under that name; this
   migration drops it and rebuilds it, so a retry does not record a name the planner
   never uses.
2. The projected-rows prune ordered its candidates by `inserted_at`, so it walked the index
   oldest first and stopped at the cutoff. That statement is gone; see "Writer stopped".

The index did not change the guards or the horizon. Rows older than the cutoff whose batch
slot was still guarded (draining epoch, open scheduled slot) were re-read through the index
each batch; that range was bounded by the expired range, not the table.

`edge_delivery_slots` (0.34 GB) and `event_ledger` (0.27 GB) prunes have the same
full-scan shape at about 26k blocks per call. They are small today; the same index plus
ORDER BY applies if they grow.

## Writer stopped (#7069)

Decision on [#7069](https://github.com/carverauto/serviceradar/issues/7069) (operator,
2026-11-26): verify, then stop writing the table. Verification found nothing that depends
on its rows:

- **Not the idempotency guard.** `EdgeRecord.run_transaction/7` upserts the delivery slot
  and `event_ledger` first; a delivery is primary only when the ledger row was freshly
  inserted (`primary?/2`). `SweepObservation.project/4` wrote the table only on a primary
  delivery, after the batch slot claim and `SweepProjection.project/3`, so a redelivery
  (`:replay`) never reached the insert and its `ON CONFLICT` never decided anything. The
  domain writes themselves upsert (`sweep_host_results` on `(execution_id, ip)`,
  `device_agent_availability` on `(device_uid, agent_id)`).
- **No reader** in Elixir, Go or Rust production code, no view, function or trigger, and
  no Ash resource. Its only readers were the retention worker and tests.
- **No spec requirement** names it; the only OpenSpec mentions were task notes listing
  the slice's tables.
- **Retention, coverage, redrive.** The ledger, delivery-slot and batch-slot prunes and
  `edge_ledger_coverage` never consult it. Dead-letter redrive and late admission go
  through the same ledger decision.

What changed:

- `SweepObservation` no longer writes the table. `ProjectionRows.row_key/2` and Go
  `projection.RowKey`, which existed only to key it, are gone.
- The tests that used its rows as the "no duplicate domain rows" artifact now check the
  domain: the Go vertical slice asserts the batch slot's `projected_row_count` and
  `committed_row_count`, the sweep execution and host rows, and that a redelivery leaves
  every `sweep_host_results` tuple version (`ctid`, `xmin`) unchanged. A re-applied upsert
  keeps the row count but always writes a new tuple version, so this fails where a row
  count cannot. `edge_record_db_test.exs` asserts the same on forced redelivery.
- The retention prune of this table is removed in the same change: nothing reads the rows,
  so there is nothing to age out. The table and its indexes stay only until the drop below.

### Dropping the table (next release)

Done in `20261127090000_drop_edge_sweep_projected_rows.exs`, as a drop plus an empty stub.

A plain `DROP TABLE` is unsafe for an installation that upgrades from a release older
than #7096 straight to the drop release: migrations run first, its old-projector cores
are still serving, and their insert would fail every sweep batch transaction on the
missing table. So the migration drops the real table (freeing all of its space) and
creates an `UNLOGGED` table with the same columns and no primary key, indexes or
constraints. The old projector inserts with `ON CONFLICT DO NOTHING` and no conflict
target, which such a table accepts, so a mixed-version rollout appends a few rows to a
small heap with no WAL or index writes, and nothing fails. Nothing reads or prunes the
stub. Drop it in a later release that enforces a minimum upgrade version at or after
#7096.

Operator decision (2026-11-27): drop the table as soon as this change is rolled out
everywhere, not after a retention horizon. Nothing reads the rows, so waiting buys nothing.

It cannot ship in this same change: migrations run before the new pods start
(`wait-migrations`), so during a rolling upgrade a core still running the old projector
would fail every sweep batch transaction on the missing table, and those edge records
would retry or dead-letter until the old pods were gone. So, in the next change, once this
one is deployed on every installation:

1. A migration that runs `DROP TABLE IF EXISTS platform.edge_sweep_projected_rows` (the
   indexes go with it), with a `down` that recreates the empty table as
   `20260910120000_create_edge_record_ledger.exs` and
   `20261126070000_index_edge_sweep_projected_rows_inserted_at.exs` define it.
2. Regenerate the baseline schema.

On demo the drop frees about 13 GB (7.4 GB heap, 5.9 GB primary key, plus the
`inserted_at` index).

Rejected, before the decision:

- **Clustered re-key** to `(network_scope_id, event_id, kind, batch_index, element_index)`.
  About 28x fewer dirtied pages and 15x less WAL in the benchmark, but still a write of
  rows nothing reads.
- **Time partitioning with partition drop.** The unique key must include the partition
  key, and it does not fix the random-key insert cost by itself.

Rejected earlier: BRIN on `inserted_at` (#7063; summaries only widen after delete plus
space reuse), a narrower hash in `row_key` (any random key has the same one-leaf-per-row
cost).

## Verify on demo after rollout

After the writer stops: the projected-rows `INSERT` disappears from `pg_stat_statements`,
`n_tup_ins` on the table stops rising, and WAL volume falls by roughly the 4 KB per
projected row measured above.

After the prune index (historical):

The projected-rows DELETE no longer runs. Nothing writes or prunes the table, and the next
PR drops it once this change is deployed everywhere. The checks below are what operators
saw after the `inserted_at` index landed, before this change removed the prune:

- The index existed and was valid: `\d platform.edge_sweep_projected_rows`.
- Historical: `pg_stat_statements` for the projected-rows DELETE showed mean time in
  milliseconds and `shared_blks_read` per call in the tens, not 500k+, while nothing had
  expired.
- Insert statement, while the writer still ran: `shared_blks_dirtied` and `wal_bytes` per
  call unchanged within noise.
- Historical, and never reached: from about 2026-12-04, when the oldest rows would have
  passed 30 days, `n_tup_del` would have risen and the worker's
  `deleted_sweep_projected_rows` log field would have been non-zero, and the heap would
  have stopped growing. The prune was removed before any row aged out.
