## Context

`add-tiered-telemetry-offload` wired the cold tier into code that runs on every deployment,
gated by configuration that no deployment supplies. Removing it is mostly deletion, but four
places mix cold-tier code with behavior every deployment depends on.

## Goals / Non-Goals

- Goals: delete the tier and all of its configuration, images, docs and tests; keep retention
  behavior for every deployment that runs with the tier disabled, which is every deployment;
  keep the continuous-aggregate safeguards that came out of the cold-tier work.
- Non-Goals: touching Parquet objects in any bucket; rewriting historical migrations;
  regenerating the schema baseline; designing a replacement archive (StarRocks owns
  long-window analytics).

## Decisions

### Retention runs unfenced

With the tier disabled, `RetentionFence.reconcile_policy/3` replaced the in-database policy
at the configured window and `safe_drop_point/3` returned the plain retention cutoff. The
worker now does both directly. The one behavioral difference is that the chunk drop no longer
runs inside a transaction holding a per-table advisory lock. That lock serialized the drop
against exporter manifest writes, and the exporter no longer exists.

### `traces_stats_5m` is reconciled like the other migration-only aggregates

The cold-tier branches did three things: skip a target shorter than the 90-day fence window
while the tier was enabled, keep an installed window of 90 days or more when
`tracesStatsDays` was unset, and skip the write when the installed window could not be read.
All three existed only so that a flag toggle would not narrow a window the fence had widened.
Without the fence the aggregate joins `@migration_caggs`: the target is the explicit
`tracesStatsDays` or the 14-day migration default, floored at the clamped refresh window, and
stays outside the `defaultDays` ceiling so existing installs keep their window. The shared
retention SQL already leaves a policy untouched when `drop_after` equals the target.

Alternative considered: keep "unset keeps a window of 90 days or more". Rejected because the
90-day figure has no meaning once the fence is gone, and keeping it would be a cold-tier rule
with no cold tier.

### The refresh-hazard check moves to an observability owner

`RetentionFence.cagg_refresh_hazards/1` runs on every deployment and has nothing to do with
offload: a continuous aggregate whose refresh window reaches its source's retention deletes
its own materialized history. It moves to `ServiceRadar.Observability.CaggRefreshHazards`.
For a source without an in-database retention policy, the fence compared the refresh window
with the configured hot window of the six registry tables. The worker drops chunks on every
raw telemetry hypertable by its own configured retention, so the fallback now uses
`DataRetentionWorker.telemetry_retention_days/1`, a superset of the registry windows with
identical values for the six tables. The check stays alert-only.

`RetentionFence.stale_invalidations/1` ran only inside an enabled exporter, so it is deleted
with the tier.

### Migrations and baseline

Historical migrations stay as they are. `20260716200000` and `20260716220000` keep creating
the tables and the role on a full replay, and the new migration removes them, so every
database converges on the same schema. Neither `20260918120000` nor `20261019160000` calls a
cold-tier module, so neither changes. The baseline (`included_through` 20261031085513) also
stays: the drop migration is newer than it and is applied on top, the way every post-baseline
migration is. The baseline is regenerated when the freshness gate requires it, not per change.

Dropping a role needs `CREATEROLE`, which the migration user lacks on a default CNPG cluster.
On that cluster the export-role migration never created `cold_reader`. Where the role exists,
the migration revokes its grants as the owner of those objects, which needs no role
privilege, and drops it only when the migration user may manage roles. Otherwise it logs a
notice. A role left behind can no longer read anything.

### Storage gauges are removed, not kept

The `serviceradar.storage.*` gauges were the tier's metering input (design D10 of the
withdrawn change). Their hot-size members ran on every deployment, but nothing scrapes them:
no dashboard, alert rule, control-plane or GitOps consumer references them. They are removed
with the tier rather than re-homed without a requirement.

## Risks / Trade-offs

- An install that once enabled the tier loses read access to its archive. No known deployment
  did. The objects stay in the bucket.
- `traces_stats_5m` narrows on the next run where the installed window is at least 90 days and
  `tracesStatsDays` is unset. Operators who want that window set `tracesStatsDays`.

## Migration Plan

Upgrade applies the drop migration. Rollback to an earlier release replays nothing, because
earlier releases never re-create objects that a later migration dropped. An earlier release
running against the dropped tables treats them as absent, which the tier already handled as
"cold tier never ran here".
