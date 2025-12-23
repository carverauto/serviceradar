# Change: Integrate Ash Framework for Multi-Tenant SaaS Platform

## Why

ServiceRadar is transitioning from a Go-based monolithic core (serviceradar-core) to an Elixir-based distributed architecture. The current Phoenix LiveView app (`web-ng`) uses standard Ecto patterns with manual context modules, basic Oban scheduling, and Phoenix.gen.auth for authentication. This approach requires significant boilerplate for:

- Multi-tenancy isolation across all queries
- RBAC and authorization enforcement
- API layer generation (REST/GraphQL)
- Job scheduling coordination
- Device/asset identity reconciliation
- Event-driven state machines for alerts/responses

The Ash Framework provides a declarative, resource-centric approach that enforces these concerns at the framework level, reducing the risk of security gaps and dramatically accelerating feature development.

**Key drivers:**
1. **Multi-tenant SaaS**: ServiceRadar needs to support customers running agents/pollers in their own networks while orchestrating from a central engine
2. **Security by default**: Authorization must be enforced at the resource level, not manually in each controller
3. **OCSF alignment**: Device inventory already follows OCSF schema; Ash resources can map directly to OCSF columns
4. **Distributed polling**: Replace Go poller with Elixir nodes coordinated via AshOban + Horde for "one big brain" architecture
5. **Replace serviceradar-core**: Port all API functionality from Go core to Ash-powered Elixir

## What Changes

### Phase 1: Foundation (Core Infrastructure)
- **AshPostgres migration**: Convert existing Ecto schemas to Ash resources with backward-compatible table mappings
- **AshAuthentication**: Replace Phoenix.gen.auth with AshAuthentication supporting:
  - Magic link email authentication
  - OAuth2 providers (Google, GitHub, etc.)
  - Password authentication (existing)
  - API tokens for CLI/external tools
- **Ash.Policy.Authorizer**: Implement RBAC with role-based policies for all resources
- **Multi-tenancy**: Add tenant context to all resources using Ash's attribute-based multi-tenancy

### Phase 2: Business Domains
Define Ash domains and resources for ServiceRadar's core entities:
- **Inventory domain**: Device, Interface, NetworkInterface, DeviceGroup
- **Infrastructure domain**: Poller, Agent, Checker, Partition
- **Monitoring domain**: ServiceCheck, HealthStatus, Metric, Alert
- **Collection domain**: Flow, SyslogEntry, SNMPTrap, OTELTrace, OTELMetric
- **Identity domain**: User, Tenant, ApiToken, Session
- **Events domain**: Event, Notification, AuditLog

### Phase 3: Job Orchestration
- **AshOban integration**: Replace custom Oban scheduler with declarative AshOban triggers
- **AshStateMachine**: Implement state machines for:
  - Alert lifecycle (pending -> acknowledged -> resolved)
  - Device onboarding (discovered -> identified -> managed)
  - Edge package delivery (created -> downloaded -> installed -> expired)
- **Polling coordination**: Define schedulable actions for service checks coordinated across distributed pollers

### Phase 4: API Layer
- **AshJsonApi**: Auto-generate JSON:API endpoints from resources
- **AshPhoenix**: Integrate Ash forms with LiveView for real-time UI
- **gRPC bridge**: Maintain gRPC for agent/checker communication (existing Go agents stay)
- **ERTS clustering**: Implement distributed Elixir for poller-to-core communication

### Phase 5: Observability & Admin
- **AshAdmin**: Admin UI for resource management during development
- **Ash OpenTelemetry**: Distributed tracing integration
- **AshAppSignal** (optional): Production monitoring integration

## Impact

### Affected Specs
- `cnpg` - Database schema additions for Ash resources and multi-tenancy
- `kv-configuration` - Minimal impact; KV patterns remain for agent config

### Affected Code
- `web-ng/lib/serviceradar_web_ng/accounts/` - Complete rewrite to AshAuthentication
- `web-ng/lib/serviceradar_web_ng/inventory/` - Convert to Ash domain
- `web-ng/lib/serviceradar_web_ng/infrastructure/` - Convert to Ash domain
- `web-ng/lib/serviceradar_web_ng/edge/` - Convert to Ash domain with state machines
- `web-ng/lib/serviceradar_web_ng/jobs/` - Replace with AshOban
- `web-ng/lib/serviceradar_web_ng_web/router.ex` - Add Ash routes, auth routes
- `web-ng/lib/serviceradar_web_ng_web/live/` - Integrate AshPhoenix.Form
- `web-ng/config/config.exs` - Ash configuration

### Breaking Changes
- **BREAKING**: API authentication flow changes (magic link, OAuth additions)
- **BREAKING**: API response format changes (JSON:API compliance)
- **BREAKING**: Database migrations for tenant_id columns on all tenant-scoped tables

### Migration Strategy
1. **Parallel resources**: Create Ash resources alongside existing Ecto schemas initially
2. **Feature flags**: Toggle between old/new implementations per-feature
3. **Data migration scripts**: Add tenant_id to existing records
4. **API versioning**: `/api/v2/` for Ash-powered endpoints while `/api/` continues working
5. **Gradual rollout**: Domain-by-domain migration with comprehensive test coverage

## Dependencies

### New Dependencies
```elixir
{:ash, "~> 3.0"}
{:ash_postgres, "~> 2.0"}
{:ash_authentication, "~> 4.0"}
{:ash_authentication_phoenix, "~> 2.0"}
{:ash_oban, "~> 0.4"}
{:ash_state_machine, "~> 0.2"}
{:ash_json_api, "~> 1.0"}
{:ash_phoenix, "~> 2.0"}
{:ash_admin, "~> 0.11"}  # dev/admin only
```

### Optional Dependencies
```elixir
{:ash_appsignal, "~> 0.1"}  # production monitoring
{:open_telemetry_ash, "~> 0.1"}  # distributed tracing
```

## Security Model

### Actor-Based Authorization
Every request carries an actor (user, API token, or system) that policies evaluate against:

```elixir
# Example: Only allow users to see devices in their tenant
policy action_type(:read) do
  authorize_if expr(tenant_id == ^actor(:tenant_id))
end

# Example: Admin bypass
bypass actor_attribute_equals(:role, :admin) do
  authorize_if always()
end
```

### Multi-Tenancy Enforcement
All tenant-scoped resources use attribute-based multi-tenancy:

```elixir
multitenancy do
  strategy :attribute
  attribute :tenant_id
end
```

### Partition Isolation
For overlapping IP spaces, partition-aware queries prevent cross-boundary data leakage:

```elixir
policy action_type(:read) do
  authorize_if expr(partition_id == ^actor(:partition_id) or partition_id == nil)
end
```

## References

- [Ash Framework Documentation](https://ash-hq.org/)
- [Ash Actors & Authorization](https://hexdocs.pm/ash/actors-and-authorization.html)
- [Ash Policies](https://hexdocs.pm/ash/policies.html)
- [AshAuthentication Phoenix](https://hexdocs.pm/ash_authentication_phoenix/get-started.html)
- [AshOban](https://hexdocs.pm/ash_oban/AshOban.html)
- [AshStateMachine](https://hexdocs.pm/ash_state_machine/getting-started-with-ash-state-machine.html)
- [ElixirConf Lisbon 2024: AshOban & AshStateMachine](https://elixirconf.com/archives/lisbon_2024/talks/bring-your-app-to-life-with-ashoban-and-ashatatemachine/)
- GitHub Issue #2205
