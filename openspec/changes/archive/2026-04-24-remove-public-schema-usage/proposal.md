# Change: Remove public schema usage from Ash migrations

## Why
Clean docker-compose installs are creating ServiceRadar tables in the `public` schema and emitting migration errors (including Timescale hypertable creation failures). This violates the platform-only schema policy and causes core-elx startup instability on fresh installs.

## What Changes
- Ensure all Ash-managed tables, indexes, and sequences are created in the `platform` schema (not `public`).
- Make hypertable/retention migrations succeed with a `platform, ag_catalog` search_path (no dependency on `public`).
- Add startup validation that fails fast if application tables remain in `public` after migrations.
- Keep every fix idempotent and delivered only via Ash migrations (no manual DB steps).

## Impact
- Affected specs: `cnpg`, `ash-domains`, `docker-compose-stack`
- Affected code: core-elx Ash resources, core-elx migration modules, startup migration checks
