## Context
Docker Compose currently bootstraps CNPG using init scripts that create roles, databases, schema, and extensions. Kubernetes/Helm uses post-init SQL or app migrations. This split makes compose fragile and creates drift whenever migrations change.

## Goals / Non-Goals
- Goals:
  - Make Docker Compose boot use Ash migrations as the source of truth for schema/extension creation.
  - Limit privileged database access to a migration-only phase.
  - Eliminate ServiceRadar-specific SQL from docker-entrypoint init scripts in compose.
  - Align Kubernetes/Helm bootstrap with the same migration-first approach.
- Non-Goals:
  - Changing production (Helm/Kubernetes) boot flow in this change.
  - Broad database privilege redesign beyond compose bootstrap.

## Decisions
- Decision: Use a dedicated migration runner in Docker Compose (one-shot core-elx service) and a core init container in Kubernetes to run migrations with a privileged role, then start app services with the app role. This avoids adding another standalone Job in k8s.
- Decision: Remove ServiceRadar-specific SQL from CNPG init scripts; rely on migrations for extensions/schema and runtime bootstrap for role/search_path grants.
- Decision: Ensure the migration runner creates the ServiceRadar application database if it is missing, without touching the SPIRE database, before running migrations.
- Decision: Store privileged credentials in a dedicated secret/volume and scope access to the migration runner only (compose volume + k8s secret).

## Alternatives Considered
- Keep CNPG init scripts in compose: rejected due to drift and duplication.
- Grant app role broad privileges permanently: rejected on least-privilege grounds.

## Risks / Trade-offs
- Using a privileged role in compose increases credential sensitivity; scope it to a one-shot migration runner and keep it out of application services.
- Migration runner ordering must be robust to avoid partial boot.

## Migration Plan
1. Add migration runner/privileged DB connection in compose.
2. Add k8s/Helm migration runner wiring (Job or init container + secret).
3. Update compose service dependencies to wait for migrations.
4. Remove ServiceRadar-specific SQL from compose CNPG init scripts.
5. Verify clean `docker compose down -v` followed by `up -d` reaches healthy state.
6. Verify Helm/k8s boot completes with migrations and healthy services.

## Open Questions
- What minimal privileges are needed for migration role (extensions + schema ownership)?
