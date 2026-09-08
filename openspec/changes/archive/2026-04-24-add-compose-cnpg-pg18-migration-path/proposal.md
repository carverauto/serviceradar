# Change: Add Docker Compose CNPG PG16-to-PG18 migration path

## Why

Docker Compose users can currently hit two opaque failure modes when they pull a
stack that targets the PG18 CNPG image while their persisted local CNPG data
volume was initialized on PG16:

- the stack lacks a supported Compose-side Postgres major-upgrade workflow
- newer credential bootstrap behavior can fail early on older installs without a
  persisted credentials volume, which obscures the underlying database-version
  mismatch

We already accept that PG18 upgrades require a controlled rollout in Helm/K8s.
Docker Compose needs the same discipline instead of trying to reuse raw local
data directories across Postgres major versions.

## What Changes

- Add a Docker Compose CNPG major-version preflight that fails fast with an
  actionable migration error when the on-disk Postgres version does not match
  the configured CNPG image major version.
- Add a supported Compose PG16-to-PG18 migration workflow for existing local
  CNPG volumes.
- Preserve ServiceRadar application access during migration by carrying forward
  the effective superuser/app/spire credential state, including legacy
  pre-credential-volume installs.
- Document the operator-facing Compose migration workflow and recovery steps.

## Impact

- Affected specs: `cnpg`, `docker-compose-stack`
- Affected code:
  - `docker-compose.yml`
  - `docker/compose/*`
  - `README-Docker.md`
  - `DOCKER_QUICKSTART.md`
  - `docs/docs/docker-setup.md`
