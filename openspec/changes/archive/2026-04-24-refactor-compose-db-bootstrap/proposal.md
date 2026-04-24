# Change: Run privileged migrations in Docker Compose bootstrap

## Why
The Docker Compose stack currently relies on CNPG init scripts to create ServiceRadar roles, schema, and extensions. This duplicates logic that already lives in the core Ash migrations and drifts from the Kubernetes/Helm path. We need a single source of truth and a reliable, idempotent boot that does not depend on database init scripts.

## What Changes
- Introduce a privileged migration path in Docker Compose and Kubernetes (migration runner or privileged connection) so Ash migrations can create required roles, schema, and extensions.
- Remove ServiceRadar-specific SQL from CNPG init scripts in the Docker Compose stack (and avoid duplicating it in Helm/K8s init hooks).
- Ensure the privileged migration phase creates the ServiceRadar application database if it does not already exist, without touching the SPIRE database.
- Keep application services running with the least-privilege database role; privileged access is limited to the migration phase.
- Update compose ordering/healthchecks and k8s deployment ordering so migrations complete before core/web-ng start.

## Impact
- Affected specs: docker-compose-stack, cnpg
- Affected code/config: docker-compose.yml, docker/compose/cnpg-init.sh, core-elx/web-ng migration configuration, Helm values/manifests, k8s job/secret wiring
