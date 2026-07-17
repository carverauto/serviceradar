# Cold tier operator runbook

Tiered telemetry offload (OpenSpec `add-tiered-telemetry-offload`). Applies
only to deployments with cold-tier configuration; without it, nothing in
this document exists at runtime.

## Mental model

- The **exporter** (hourly) copies closed hypertable chunks to Parquet on
  the deployment bucket via the analytics head, verifies each object with a
  dual-engine checksum, and records it in `platform.cold_chunk_exports`.
- The **retention fence** only lets `drop_chunks` remove data that is
  verified-exported, below the head-acknowledged query boundary, and
  re-verified at drop time. If exports stall, data is HELD hot — never
  silently lost.
- The **pruner** (nightly) tombstones archive objects past the cold window,
  deletes them, and reconciles manifest vs bucket (including aborting stale
  multipart uploads — bucket lifecycle rules are not trusted).

## Alerts and what they mean

| Log message contains | Meaning | Action |
|---|---|---|
| `Cold tier pressure: database volume N% used` | Held chunks + normal growth approaching volume capacity (70/85/95%) | Fix the export path (head/object store); consider volume expansion; last resort: emergency drop |
| `chunk quarantined after repeated export failures` | Poison chunk blocks the frontier | Break-glass export below |
| `in-database retention policies exist on fenced tables` | A migration/manual DDL re-armed a Timescale policy | Remove it (`SELECT remove_retention_policy('platform.<t>')`); find the source |
| `Continuous aggregates refresh past their raw source's retention` | Refresh window reaches dropped-raw regions — policy refreshes DELETE materialized history | Clamp the policy's `start_offset` below the source retention |
| `pending CAGG invalidations older than the hot boundary` | "Loaded gun": a covering refresh would delete CAGG history | Verify refresh windows are clamped; do NOT run wide manual refreshes |
| `verified manifest rows reference MISSING archive objects` | Archive objects deleted outside the pruner | Investigate bucket access/lifecycle; affected ranges are unreadable cold |
| `Cold tier is DISABLED but un-drained state remains` | Two-phase disable pending | See "Disabling the cold tier" |

## Export stalled (head down, object store down, credentials broken)

1. Nothing is lost while stalled: the fence holds chunks hot. Watch the
   pressure alerts for headroom.
2. Head down: fix/restart the analytics head cluster. Exports resume where
   the manifest left off; the frontier only advances over verified chunks.
3. Credentials: the exporter re-asserts the head's FDW server/user mapping
   and S3 secret from mounted secrets on every run. After rotating secrets,
   the next run picks them up; sessions are never reused across errors.
4. Never cancel an in-flight exporter `COPY` (`pg_cancel_backend`,
   `pg_terminate_backend`, timeouts): it produces corrupt-but-complete
   objects, can poison sessions, and can crash the head's postmaster. The
   exporter's units are input-sized precisely so waiting is safe.

## Break-glass: poison chunk (quarantined)

A chunk that repeatedly fails export blocks the frontier (by design).

1. Inspect: `SELECT * FROM platform.cold_chunk_exports WHERE status='quarantined';`
   plus the `last_error` column and head logs.
2. Common causes: a value overflowing checksum quantization, corrupt rows,
   head OOM on an oversized chunk (temporarily raise `duckdb.max_memory`
   or export a sub-range by hand).
3. Manual export path (bypasses the exporter, same contract): on the head,
   `COPY (SELECT <registry column list> FROM fdw_primary.<table> WHERE
   <time range>) TO 's3://<bucket>/<deterministic key>' (FORMAT parquet,
   COMPRESSION zstd);` then verify counts via `read_parquet`, and update the
   manifest row to `verified` with the row_count.
4. If the data is genuinely unexportable and must be discarded:
   `ServiceRadar.ColdTier.Admin.emergency_drop/3` (below) scoped tightly to
   the poison range.

## Emergency pressure relief (volume about to fill)

Operator-acknowledged, permanently discards un-exported data in the range:

```
bin/serviceradar_core rpc 'ServiceRadar.ColdTier.Admin.emergency_drop(
  "timeseries_metrics", "2026-07-01T00:00:00Z", confirm: "DROP-WITHOUT-EXPORT")'
```

The call reports how many dropped chunks had no verified export. Prefer
volume expansion and fixing the export path first.

## Disabling the cold tier (two-phase)

1. Unset `SERVICERADAR_COLD_TIER_ENABLED`. Retention stays FENCED: only
   verified-exported data drops; un-exported chunks are held and the
   retention worker alerts that the disable is un-drained.
2. Either let exports finish draining (re-enable until the frontier covers
   everything you care about), or explicitly waive:

```
bin/serviceradar_core rpc 'ServiceRadar.ColdTier.Admin.waive(
  :all, confirm: "DISCARD-UNEXPORTED")'
```

After the waive, standard retention policies re-arm on the next retention
run. Archived Parquet already in the bucket is untouched (prune it manually
if the deployment is being retired).

## Secret rotation

1. Update the mounted Kubernetes secrets (cold-tier S3 credentials,
   `cold_reader` password on the primary).
2. The exporter's next run re-asserts head-side objects (drops duplicate S3
   secrets, recreates the FDW user mapping). Force it immediately with:
   `bin/serviceradar_core rpc 'ServiceRadar.ColdTier.Exporter.run()'`.
