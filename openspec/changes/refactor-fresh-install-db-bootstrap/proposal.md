# Change: Refactor fresh-install database bootstrap

## Why
Fresh ServiceRadar installs currently replay the full historical migration chain before core-dependent services can start. A clean database has no product data to migrate, but startup still runs hundreds of historical schema, repair, backfill, rollup, and policy steps as if it were upgrading a long-lived deployment.

This makes first boot slow and fragile, hides real SQL timing behind migration-runner overhead, and couples operational maintenance to the install-critical path.

## What Changes
- Introduce a canonical current-schema baseline for fresh platform databases.
- Detect empty databases and apply the baseline directly instead of replaying historical migrations.
- Mark all migrations included in the baseline as applied in the platform migration ledgers.
- Preserve normal migration execution for existing deployments that already have migration history.
- Move data backfills, continuous aggregate refreshes, and operational repair work out of synchronous startup migrations and into explicit post-bootstrap jobs or runbooks.
- Add CI and Docker Compose/Helm smoke coverage that enforces bounded clean-install bootstrap time.

## Non-Goals
- No tactical optimization that only makes `step: 1` migration replay faster.
- No destructive reset path for existing databases.
- No removal of upgrade migrations required by already deployed versions.

## Impact
- Affected specs: database-bootstrap
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/cluster/startup_migrations.ex`
  - `elixir/serviceradar_core/priv/repo/migrations/`
  - new baseline schema artifact(s) under the core repo
  - Docker Compose and Helm migration/bootstrap jobs
  - CI release/bootstrap validation
- Operational impact:
  - New installs become baseline-first.
  - Existing installs continue to upgrade through pending migrations.
  - Maintenance/backfill work becomes observable and retryable outside first boot.
