# Change: Fix Oban tables missing from platform schema on fresh installs

## Why

Fresh docker-compose installs fail with `ERROR 42P01 (undefined_table) relation "platform.oban_jobs" does not exist`. This prevents users from logging into the UI and blocks Oban job processing for events, integrations, and service checks.

The root cause is that `Oban.Migrations.up()` in the first migration (20260117090000_rebuild_schema.exs) does not specify `prefix: "platform"`, causing Oban tables to be created in the `public` schema while the application is configured to use `platform.oban_jobs`.

## What Changes

- Add a new migration that explicitly creates Oban tables in the `platform` schema if they don't exist, running early in startup
- Update the existing `ensure_oban_platform_tables` migration to be more robust with better error handling
- Add startup validation in `ServiceRadar.Cluster.StartupMigrations` to verify Oban tables exist before starting Oban
- Improve logging to help diagnose schema issues on fresh installs

## Impact

- Affected specs: `ash-jobs`
- Affected code:
  - `elixir/serviceradar_core/priv/repo/migrations/20260123205147_ensure_oban_platform_tables.exs`
  - `elixir/serviceradar_core/lib/serviceradar/cluster/startup_migrations.ex`
  - `elixir/serviceradar_core/lib/serviceradar/application.ex` (startup validation)
