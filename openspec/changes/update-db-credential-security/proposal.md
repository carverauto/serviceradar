# Change: Harden database credentials and exposure defaults

## Why
Default database credentials and public bindings increase risk in both Docker Compose and Helm/Kubernetes deployments. Issue 2485 calls out the `postgres` default password, static app passwords, and unintended public exposure.

## What Changes
- Generate random Postgres superuser and app (serviceradar/spire) passwords when not explicitly provided, persisting them in Kubernetes secrets or Docker volumes.
- Reuse existing secrets/volume files on restarts to avoid unintended password rotation.
- Require explicit credential seeding for existing Docker Compose data volumes (no legacy defaults).
- Default Docker Compose CNPG port binding to loopback instead of all interfaces.
- Document the new credential bootstrap behavior and explicit steps for opting into external DB exposure.

## Impact
- Affected specs: `cnpg`, `docker-compose-stack`
- Affected code: `helm/serviceradar/templates/spire-postgres.yaml`, `helm/serviceradar/values.yaml`, `docker-compose.yml`, `docker/compose/cnpg-init.sql`, Docker Compose helper scripts and docs
