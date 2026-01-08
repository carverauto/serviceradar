# Change: Enforce tenant schema isolation and auto-migrations

## Why
Tenant data must be physically isolated in per-tenant PostgreSQL schemas, and core-elx should apply migrations automatically so operators are not required to run manual steps.

## What Changes
- **BREAKING**: All tenant-scoped Ash resources move to schema-based multitenancy (context strategy) with tenant-specific schemas named `tenant_<slug>`.
- Tenant schema creation and tenant migrations run automatically when a tenant is provisioned (including the platform tenant).
- core-elx runs Ash migrations on startup for public and tenant schemas, and fails fast if migrations cannot be applied.
- Public schema remains for platform-managed resources only (tenants, tenant memberships, NATS platform tables, platform Oban/jobs); platform tenant data lives in its own tenant schema, and tenant-scoped identity data (ng_users, API tokens, user tokens) moves into tenant schemas.
- Tenant context for API operations MUST be derived from authenticated scope or onboarding token lookup; request-supplied tenant headers are not accepted for tenant selection.
- Tenant AshOban job schedules and tenant Oban jobs are stored in tenant schemas.
- Multi-tenant authentication SHALL resolve tenant context from vanity domains when present, and fall back to a tenant selection step only when multiple tenants exist and no default tenant is configured; single-tenant installs auto-select the default tenant without a prompt.

## Impact
- Affected specs: tenant-isolation, ash-domains, cnpg.
- Affected code: Ash resources across core-elx, tenant bootstrap and provisioning flows, migration runner and startup sequence.
- Data impact: no production migration needed; dev/test databases can be rebuilt.

## Out of Scope
- Tenant-aware OTEL routing and NATS stream/account segmentation for telemetry ingestion.

## Implementation Notes

### Tenant Context via Ash.Scope Pattern

Instead of threading `actor` and `tenant` as separate parameters through all helper functions, we use the `Ash.Scope` pattern where a `scope` struct is passed and Ash automatically extracts what it needs via protocols.

#### Protocol Implementations

1. **`Ash.ToTenant` for `ServiceRadar.Identity.Tenant`** (in `serviceradar_core/lib/serviceradar/identity/tenant_to_tenant.ex`)
   - Converts tenant struct to the appropriate identifier based on multitenancy strategy
   - For `:context` strategy: returns schema name (e.g., `"tenant_platform"`)
   - For `:attribute` strategy: returns tenant ID (UUID)

2. **`Ash.Scope.ToOpts` for `ServiceRadarWebNG.Accounts.Scope`** (in `lib/serviceradar_web_ng/ash_tenant.ex`)
   - `get_actor/1` - returns the user from `scope.user`
   - `get_tenant/1` - returns the tenant from `scope.active_tenant`
   - `get_context/1` - returns tenant_memberships in shared context for policies

#### Usage Pattern

```elixir
# In LiveViews - extract scope from socket assigns
scope = socket.assigns.current_scope

# Pass scope to Ash operations
Ash.read(query, scope: scope)

# Or through SRQL
srql_module.query(query, %{scope: scope})
```

#### Files Implementing This Pattern

- `lib/serviceradar_web_ng/ash_tenant.ex` - Protocol implementation
- `lib/serviceradar_web_ng/srql.ex` - Accepts `scope:` option
- `lib/serviceradar_web_ng/srql/ash_adapter.ex` - Passes `scope:` to Ash.read()
- `lib/serviceradar_web_ng_web/srql/page.ex` - Extracts scope from socket
- `lib/serviceradar_web_ng_web/live/*` - All LiveViews use scope pattern
- `lib/serviceradar_web_ng_web/stats.ex` - Stats module accepts scope
