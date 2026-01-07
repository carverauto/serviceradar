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
- Preserve `public` schema for platform-managed resources only (tenants, tenant memberships, NATS platform tables, platform Oban jobs).
- Create tenant schemas named `tenant_<slug>` (slug sanitized) and run tenant migrations immediately, including for the platform tenant.
- Use a shared tenant migration set (`priv/repo/tenant_migrations`) applied to every tenant schema.
- core-elx runs Ash migrations on startup for the public schema and all tenant schemas. Startup fails if migrations cannot be applied.
- Tenant-scoped tokens (API tokens, user tokens) live in tenant schemas and require tenant context for lookup.
- Tenant AshOban job schedules and tenant Oban jobs live in tenant schemas; platform jobs remain in public.

## Resource Inventory (Tenant vs Public)
Tenant-scoped resources (schema-based `:context`):
- ServiceRadar.Identity.ApiToken
- ServiceRadar.Identity.Token
- ServiceRadar.Identity.User
- ServiceRadar.Identity.DeviceAliasState
- ServiceRadar.Inventory.Device
- ServiceRadar.Inventory.DeviceGroup
- ServiceRadar.Inventory.DeviceIdentifier
- ServiceRadar.Inventory.Interface
- ServiceRadar.Inventory.MergeAudit
- ServiceRadar.Infrastructure.Agent
- ServiceRadar.Infrastructure.Gateway
- ServiceRadar.Infrastructure.Checker
- ServiceRadar.Infrastructure.Partition
- ServiceRadar.Infrastructure.HealthEvent
- ServiceRadar.Integrations.IntegrationSource
- ServiceRadar.Monitoring.Alert
- ServiceRadar.Monitoring.Event
- ServiceRadar.Monitoring.PollJob
- ServiceRadar.Monitoring.PollingSchedule
- ServiceRadar.Monitoring.ServiceCheck
- ServiceRadar.Jobs.JobSchedule
- ServiceRadar.Edge.CollectorPackage
- ServiceRadar.Edge.EdgeSite
- ServiceRadar.Edge.NatsCredential
- ServiceRadar.Edge.NatsLeafServer
- ServiceRadar.Edge.OnboardingEvent
- ServiceRadar.Edge.OnboardingPackage
- ServiceRadar.Edge.TenantCA
- ServiceRadar.Observability.CpuMetric
- ServiceRadar.Observability.DiskMetric
- ServiceRadar.Observability.MemoryMetric
- ServiceRadar.Observability.ProcessMetric
- ServiceRadar.Observability.TimeseriesMetric
- ServiceRadar.Observability.Log
- ServiceRadar.Observability.OtelMetric
- ServiceRadar.Observability.OtelTrace
- ServiceRadar.Observability.OtelTraceSummary

Public/shared resources (public schema; tenant data not stored here):
- ServiceRadar.Identity.Tenant
- ServiceRadar.Identity.TenantMembership (attribute strategy)
- ServiceRadar.Infrastructure.NatsOperator
- ServiceRadar.Infrastructure.NatsPlatformToken
- Platform Oban/maintenance tables remain public (Oban.Job, Oban.Pro)

## Risks / Trade-offs
- Startup time increases due to migration execution.
- Requires strict ordering so migrations run before Oban/AshOban jobs and application boot logic that assumes tables exist.

## Migration Plan
1. Identify tenant-scoped resources and define tenant migrations.
2. Add a migration runner that applies public and tenant migrations at startup.
3. Create tenant schemas as part of provisioning; rebuild dev/test DBs as needed.
4. Move tenant job schedules into tenant migrations; keep platform job schedules public if needed.

## Open Questions
- None.
