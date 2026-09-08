## Context
The current startup migration path uses Ecto migrations as both upgrade history and first-install provisioning. On a clean Docker Compose install, the migration logs show many migrations completing in `0.0s` while wall-clock gaps between migrations dominate startup. The system also runs historical continuous aggregate refreshes, backfills, repair updates, and extension/policy maintenance synchronously before the stack can finish booting.

That model is correct for upgrading existing deployments, but wrong for an empty database. A clean install needs the current desired schema and required extension/policy state, not every historical transition that led to it.

## Goals
- Make fresh database bootstrap apply the current platform schema directly.
- Keep upgrade behavior safe for existing databases.
- Keep every schema object in the `platform` schema, with `ag_catalog` only in search path where needed.
- Make post-schema maintenance explicit, observable, retryable, and outside the critical first-boot path.
- Provide a repeatable way to regenerate and validate the baseline during releases.

## Non-Goals
- Do not bypass schema governance by allowing Go services or ad hoc scripts to create ServiceRadar tables.
- Do not apply the baseline to non-empty or partially migrated databases.
- Do not collapse all future schema evolution into manual SQL edits; normal migrations remain the upgrade mechanism.

## Proposed Design

### Baseline Artifact
Maintain a canonical baseline artifact representing the current empty-platform schema. The baseline includes:
- required extensions and schemas;
- platform tables, indexes, constraints, functions, views, materialized views, continuous aggregates, policies, and grants;
- migration ledger rows for all migrations included in the baseline.

The baseline must be generated from the same Elixir migration authority used for upgrades, then committed as a reviewed artifact. Release tooling validates that a database created from scratch by replaying migrations matches a database created from the baseline.

### Bootstrap Decision
Startup migration code classifies the database before applying changes:
- **Empty database**: no platform schema objects beyond bootstrap metadata and no migration ledger rows. Apply the baseline and insert included migration versions.
- **Migrated database**: migration ledger exists with versions. Run pending migrations normally.
- **Ambiguous database**: platform objects exist without coherent migration metadata. Fail closed with an actionable repair message.

The baseline path must never run on an existing deployment unless the database is proven empty.

### Migration Boundary
Record a baseline version marker, for example the highest migration version included in the baseline plus a baseline artifact checksum. New migrations after that marker run normally on both baseline-created databases and upgraded databases.

Historical migrations remain in the repo long enough to support upgrades from supported older versions, but fresh installs do not replay them.

### Maintenance and Backfills
Separate schema creation from operational data work:
- backfills and cleanup updates become named, idempotent jobs with progress tracking;
- continuous aggregate refreshes run through Timescale policies or explicit post-bootstrap jobs;
- large repair operations do not block first boot;
- startup may enqueue required maintenance, but service readiness must not depend on empty-database backfills.

### Validation
CI validates:
- migration replay schema equals baseline schema for an empty database;
- Docker Compose clean install reaches healthy services within a bounded window;
- Helm install/upgrade chooses the right bootstrap path;
- ambiguous databases fail with an actionable error.

## Risks
- Schema diff validation needs to account for nondeterministic catalog ordering and extension-owned objects.
- Existing historical migrations may not be replayable forever as extensions or PostgreSQL versions change; support windows should be explicit.
- Moving backfills out of migrations requires clear operational visibility so upgrade work is not silently skipped.
