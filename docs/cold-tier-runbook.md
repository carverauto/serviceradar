# Cold tier operator runbook

## Consistency contract (what the tiers guarantee)

- **No committed row is ever absent from both tiers.** A chunk drops only
  when it is verified-exported, entirely below the head-acknowledged query
  boundary, and re-verified at drop time. If any of those fails, the data
  stays hot (and pressure alerts fire) — the system holds data rather than
  losing it.
- **The overlap zone is eventually consistent.** Between export and drop, a
  range exists in both tiers. Rows that arrive late into an already-exported
  chunk are visible to hot queries immediately and to the cold tier after
  the next pre-drop refresh (≤ one exporter run, hourly by default); the
  drop gate re-verifies and re-exports on drift, so nothing is dropped
  un-captured. Update-prone tables (`ocsf_events`, whose findings are
  upserted after insert) are re-exported unconditionally near their drop
  point, because an in-place update leaves row counts unchanged.
- **Staleness bound**: a mutation landing after a chunk's final re-export
  and before its drop is lost. Keeping the export lag (48h default) well
  inside the hot window keeps that window at hours, not days.
- **Archived objects are immutable.** Cold data is never updated in place;
  a re-export overwrites a deterministic key wholesale.
- **Verification, not existence.** An object at the expected key proves
  nothing: a cancelled COPY leaves a complete-looking but truncated object.
  Only a manifest row marked `verified` (row count + content checksum
  agreeing across PostgreSQL and Parquet) admits data to the cold tier.
- **Continuous aggregates are unaffected.** CAGGs materialize from hot data
  minutes after ingest and keep their own retention; offload never feeds
  them. Their refresh windows are clamped inside raw retention precisely so
  a refresh can never recompute a dropped region into oblivion.

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

## What the cold tier costs a deployment that never enables it

Nothing that runs, and nothing that grows. The feature ships in every build but
is inert until switched on:

- no supervised processes and no Oban workers -- the exporter, pruner and
  pressure monitor are only reachable from the retention worker's cold-tier
  branches, which return immediately when the tier is disabled;
- two empty tables (`platform.cold_tier_boundaries`,
  `platform.cold_chunk_exports`) from the manifest migration;
- a `cold_reader` role created `NOLOGIN`, carrying SELECT-only grants and
  role-level timeouts but no ability to connect (see below);
- no image, no extension, no `postgres_fdw` server, no object-store client;
- retention behaves exactly as it did before: the fence only engages once the
  tier is enabled, so `drop_chunks` runs on the plain retention cutoff.

Rollup retention windows are NOT widened until the tier is enabled -- see
"Rollup retention widening" below.

## Enabling the cold tier

The analytics head, the export role, and the runtime are three separate
switches; turning on only one leaves the others inert (by design -- an idle
head is cheaper to diagnose than a half-live pipeline).

1. **Export role.** In Kubernetes set `coldTier.exportRole.enabled=true` and
   point `coldTier.exportRole.passwordSecret` at a `kubernetes.io/basic-auth`
   Secret whose `username` is `cold_reader`. CNPG's `managed.roles` then owns
   the role's login and password, reconciled continuously so it survives
   migration ordering and failover. The render fails rather than defaulting the
   Secret name.

   In compose/dev, set `SERVICERADAR_COLD_TIER_PRIMARY_FDW_PASSWORD` (or
   `..._FILE`) before running migrations; the migration grants `LOGIN` in the
   same statement that sets the password.

   Until one of those happens the role stays `NOLOGIN` and cannot authenticate
   regardless of `pg_hba.conf`.

2. **Analytics head.** `coldTier.analyticsHead.enabled=true`. Never point it at
   the primary image: pg_duckdb is structurally incompatible with a
   TimescaleDB-loaded instance.

3. **Runtime.** `SERVICERADAR_COLD_TIER_ENABLED=true` plus the bucket and
   head/primary connection settings. Incomplete config resolves to
   `:misconfigured`, which does NOT fence retention -- the retention worker
   logs loudly instead, so a dead exporter cannot silently fill the primary.

## Rollup retention widening

Once the tier is enabled, the retention worker widens the continuous aggregates
whose windows are shorter than a cold deployment can usefully look back
(`ocsf_events_hourly_stats`, `traces_stats_5m`,
`ocsf_network_activity_hourly_{proto,talkers,ports}`) to 90 days. Raw history
past the hot window comes from cold objects, but the stats surfaces over that
same range are served by these in-database rollups, so a 24-hour rollup under a
90-day cold window leaves them blank.

This is widen-only, and it is deliberately not reversed on disable: shrinking a
window back would DELETE the materialized history between the two, and toggling
a flag must never be a data-deletion event. To reclaim that storage after
disabling, narrow the policy yourself, e.g.:

```sql
SELECT remove_retention_policy('platform.ocsf_events_hourly_stats', if_exists => true);
SELECT add_retention_policy('platform.ocsf_events_hourly_stats', INTERVAL '1 day');
```

A CAGG with no retention policy at all is left alone -- installing one would
delete everything past the window.

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
if the deployment is being retired). Widened rollup windows also stay widened
-- see "Rollup retention widening" for why, and how to reclaim the storage.

To take the export role's login away again, set
`coldTier.exportRole.enabled=false`. Note that CNPG only manages roles it is
told about, so removing the block stops it reconciling the role but does not
revoke the login it already granted; `ALTER ROLE cold_reader NOLOGIN` does.

## Secret rotation

1. Update the mounted Kubernetes secrets (cold-tier S3 credentials,
   `cold_reader` password on the primary).
2. The exporter's next run re-asserts head-side objects (drops duplicate S3
   secrets, recreates the FDW user mapping). Force it immediately with:
   `bin/serviceradar_core rpc 'ServiceRadar.ColdTier.Exporter.run()'`.
