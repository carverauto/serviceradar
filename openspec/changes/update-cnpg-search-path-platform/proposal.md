# Change: Enforce platform-first CNPG search_path

## Why
Recent Helm upgrades in demo-staging allowed Postgres to prefer the public schema, causing new tables (including Oban) to be created outside the platform schema and breaking ownership assumptions. This needs to be deterministic and idempotent for fresh installs and upgrades.

## What Changes
- Ensure CNPG bootstrap sets the database search_path to `platform, ag_catalog` (no public preference).
- Ensure the `platform` schema exists and is owned by the `serviceradar` role before app migrations run.
- Align Docker Compose and Helm CNPG bootstrap behavior so new installs cannot drift into public.

## Impact
- Affected specs: `cnpg`
- Affected code: `helm/serviceradar/templates/spire-postgres.yaml`, `docker/compose/cnpg-init.sql`
- Potentially requires a one-time owner fix for existing clusters that already created tables under `public`
