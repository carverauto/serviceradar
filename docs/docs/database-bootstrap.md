---
title: Database Bootstrap
---

# Database Bootstrap

ServiceRadar uses two database startup paths:

- Fresh installs apply the committed platform schema baseline from
  `elixir/serviceradar_core/priv/repo/baseline/`.
- Existing installs run only pending migrations after their recorded migration
  ledger state.

The baseline path exists so a new database gets the current schema directly
instead of replaying every historical upgrade migration. Upgrade migrations
remain the source of truth for existing deployments.

## Fresh Install

On startup, core classifies the database before applying schema changes. A
database is treated as empty only when there are no platform-owned schema
objects beyond bootstrap metadata and no migration ledger rows.

For an empty database, startup:

1. Applies `platform_schema.sql` through the core Postgrex connection.
2. Verifies the baseline checksum from `metadata.json`.
3. Inserts `platform.schema_migrations` rows for every migration included in
   the baseline marker.
4. Records the applied baseline in `platform.serviceradar_schema_baselines`.
5. Runs any migrations newer than the baseline marker.

## Existing Install

If `platform.schema_migrations`, `platform.ash_schema_migrations`, or legacy
`public.schema_migrations` contains migration rows, startup does not apply the
baseline. It preserves the upgrade path and runs pending migrations normally.

## Ambiguous State

If platform objects exist but migration metadata is missing, startup fails
closed. Restore from backup or repair the migration ledger before retrying. Do
not force the baseline over a partially created database.

## Regenerating the Baseline

Regenerate the baseline from a fully migrated empty database:

```bash
DATABASE_URL='postgres://...' scripts/db/generate-platform-baseline.sh
```

Compare a baseline-created database against a migration-replayed database:

```bash
BASELINE_DATABASE_URL='postgres://...' \
REPLAY_DATABASE_URL='postgres://...' \
scripts/db/compare-platform-baseline.sh
```

The Elixir quality workflow runs this comparison when the
`SERVICERADAR_BASELINE_DATABASE_URL` and `SERVICERADAR_REPLAY_DATABASE_URL`
secrets are configured.

Commit both `platform_schema.sql` and `metadata.json` whenever the baseline is
intentionally refreshed.

## Startup-Safety Checks

Run the static guard before adding migrations after the baseline:

```bash
scripts/db/check-migration-startup-safety.sh
```

The guard blocks new migrations from adding synchronous data backfills,
continuous aggregate refreshes, retention-policy maintenance, sleeps, or broad
platform updates to the first-boot path.

## Maintenance Boundary

Schema migrations may create or alter schema objects needed for the application
to start. They must not use first boot to repair historical product data,
refresh continuous aggregates, run cleanup sweeps, or backfill large tables.

Put that work in one of these places instead:

- an idempotent Oban worker with progress recorded in a platform table;
- a bounded operator runbook under `docs/docs/`;
- a Timescale policy that refreshes asynchronously after startup.

If a migration must perform a bounded maintenance operation before the service
can safely start, include a reviewed comment containing
`serviceradar:allow-startup-maintenance` that explains the startup impact.

For an isolated clean-install timing smoke test:

```bash
APP_TAG=sha-<commit> scripts/db/docker-compose-bootstrap-smoke.sh
```

By default the smoke test uses a separate Compose project named
`serviceradar-bootstrap-smoke`, sets `SERVICERADAR_VOLUME_PREFIX` to match that
project, and removes its volumes on exit. Set `SERVICERADAR_BOOTSTRAP_KEEP_STACK=1`
to keep the stack for debugging.
