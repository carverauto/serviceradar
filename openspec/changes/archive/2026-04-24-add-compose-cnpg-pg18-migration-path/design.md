## Context

Kubernetes/Helm rollouts already treat the PG18 move as a controlled CNPG major
upgrade. Docker Compose does not have the CNPG operator or managed PVC
workflows, so it needs an explicit local-volume migration path. Compose users
typically have:

- a persisted `cnpg-data` Docker volume
- a `cert-data` volume for local mTLS
- either a `cnpg-credentials` volume (newer installs) or legacy static/default
  database credentials with no persisted credential volume

Trying to start PG18 directly on a PG16 data directory is not a supported
Postgres major upgrade. The right behavior is:

1. fail fast with the real cause
2. provide a one-shot migration workflow
3. preserve application connectivity after migration

## Goals / Non-Goals

- Goals:
  - Detect PG16-on-PG18 Compose upgrades before CNPG attempts to boot.
  - Provide a supported Compose migration path from PG16 to PG18.
  - Preserve ServiceRadar application data and effective DB credentials.
  - Keep the workflow operator-friendly for single-host Docker installs.
- Non-Goals:
  - Automating Kubernetes/CNPG operator upgrades.
  - Zero-downtime upgrade for local Docker Compose installs.
  - Generalized major-version upgrades beyond the supported PG16-to-PG18 path.

## Decisions

- Decision: Compose will use a fail-fast CNPG preflight that reads `PG_VERSION`
  from the mounted data directory and blocks unsupported direct starts.
  - Why: This surfaces the real failure immediately and prevents time-consuming
    misdiagnosis in cert/bootstrap layers.

- Decision: The Compose upgrade workflow will use a controlled logical migration
  for local Docker volumes instead of attempting an in-place binary upgrade.
  - Why: The operator-driven K8s path does not exist in Compose, and a logical
    migration is more portable and easier to reason about across developer
    machines than a custom `pg_upgrade` packaging story.

- Decision: The migration workflow will preserve the effective superuser/app
  credential state, including legacy installs that never had a
  `cnpg-credentials` volume.
  - Why: The upgraded stack must come back with the same database access model
    the user already depends on.

## Risks / Trade-offs

- Logical migration is slower than direct file-level upgrades on large local
  datasets.
- Extension/version compatibility must be validated during restore.
- Operators need a clear volume-backup step before the migration mutates local
  state.

## Migration Plan

1. Add the CNPG version preflight to stop unsupported direct PG16-on-PG18 boots.
2. Add the Compose migration workflow and document the backup/rollback steps.
3. Validate the workflow against a seeded PG16 Docker volume and a migrated PG18
   target volume.
4. Update Docker Compose docs to route operators to the migration workflow when
   the preflight trips.

## Open Questions

- Should the migration workflow write into a new target volume and require an
  explicit promotion step, or should it promote in place after taking a backup
  snapshot of the original volume?
