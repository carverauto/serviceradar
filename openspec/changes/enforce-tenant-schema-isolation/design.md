## Context
ServiceRadar currently relies on attribute-based multitenancy in public schema tables. This does not provide physical isolation and requires manual migration steps. We need schema-per-tenant isolation as the default, and core-elx must run migrations automatically at startup.

## Goals / Non-Goals
- Goals:
  - Enforce schema-based multitenancy for all tenant-scoped resources.
  - Automatically create and migrate tenant schemas on tenant provisioning.
  - Run Ash migrations on core-elx startup and fail fast on errors.
- Non-Goals:
  - Redesign OTEL routing or NATS tenant stream/account architecture.
  - Change edge onboarding package behavior in this change.

## Decisions
- Use `strategy :context` for tenant-scoped Ash resources and apply tenant schema prefixes via the core repository.
- Preserve `public` schema for platform-managed resources only (tenants, users, tenant memberships, NATS platform tables, Oban, job schedules).
- Create tenant schemas named `tenant_<slug>` (slug sanitized) and run tenant migrations immediately, including for the platform tenant.
- core-elx runs Ash migrations on startup for the public schema and all tenant schemas. Startup fails if migrations cannot be applied.
- Tenant-scoped tokens (API tokens, user tokens) live in tenant schemas and require tenant context for lookup.

## Risks / Trade-offs
- Startup time increases due to migration execution.
- Requires strict ordering so migrations run before Oban/AshOban jobs and application boot logic that assumes tables exist.

## Migration Plan
1. Identify tenant-scoped resources and define tenant migrations.
2. Add a migration runner that applies public and tenant migrations at startup.
3. Create tenant schemas as part of provisioning; rebuild dev/test DBs as needed.

## Open Questions
- None.
