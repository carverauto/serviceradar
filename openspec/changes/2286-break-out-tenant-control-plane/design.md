# Design: Break out Tenant/SaaS Control Plane

## North Star

**`helm install serviceradar` or `docker compose up` MUST give you a fully working single-tenant system with zero Control Plane dependencies.**

## Key Insight: Identical Deployments

A Tenant Instance is **always the same deployment** whether it's:
- OSS single-tenant install
- One of many instances managed by the SaaS Control Plane

```
┌─────────────────────────────────────────────────────────────────┐
│                     Tenant Instance (identical)                  │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐        │
│  │ core-elx │  │  web-ng  │  │ checkers │  │  agents  │        │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘        │
│       │             │             │             │               │
│       └─────────────┴─────────────┴─────────────┘               │
│                           │                                      │
│              ┌────────────┴────────────┐                        │
│              ▼                         ▼                        │
│     NATS (tenant creds)        CNPG (tenant schema)             │
└─────────────────────────────────────────────────────────────────┘

Control Plane (serviceradar-web/) - ONLY does:
  • Create CNPG users + schemas
  • Create NATS accounts
  • Deploy/scale Tenant Instances
  • Signup, billing, tenant management UI
```

The Control Plane doesn't change the tenant instance code - it just provisions more of them.

## Context

The current architecture has significant complexity due to mixing SaaS control plane responsibilities with tenant runtime code. This results in:

1. **Security concerns**: `core-elx` has "super power" access over the entire database via SystemActor.platform() and authorize?: false patterns
2. **Code complexity**: Mixed multi-tenancy logic with schema-based isolation for some resources and attribute-based for others
3. **Deployment complexity**: Single deployment model tries to serve both OSS single-tenant and SaaS multi-tenant use cases

### Current State Analysis (Deep Dive Findings)

#### SystemActor Usage Patterns

**Legitimate Control Plane Operations** (should move to Control Plane):
- `tenant_bootstrap`, `platform_tenant_bootstrap` - Tenant lifecycle management
- `operator_bootstrap`, `nats_account_worker` - NATS infrastructure provisioning
- `tenant_registry_loader` - Cross-tenant slug registry (for routing)
- `template_seeder`, `rule_seeder`, `zen_rule_seeder` - Default data seeding
- `event_publisher` - Cross-tenant event publishing
- `tenant_workload_credentials` - Tenant credential generation
- `sync_config_generator` - Platform-wide integration sync

**Tenant-Scoped Operations** (remain in Tenant Instance):
- `state_monitor`, `health_tracker` - Infrastructure monitoring
- `sweep_ingestor`, `sweep_compiler`, `sweep_monitor` - Sweep processing
- `config_server`, `gateway_sync` - Agent configuration
- `alert_engine`, `log_promotion` - Observability
- `sync_ingestor`, `device_actor` - Inventory management

#### authorize?: false Violations

**Production code using authorize?: false** (security risk):

| Location | Description | Action Required |
|----------|-------------|-----------------|
| `elixir/web-ng/lib/serviceradar_web_ng/inventory.ex:120` | Hardcoded system_actor + authorize?: false | Remove fallback |
| `elixir/web-ng/lib/serviceradar_web_ng/infrastructure.ex:135` | Same pattern | Remove fallback |
| `elixir/web-ng/lib/serviceradar_web_ng_web/tenant_resolver.ex` | Hardcoded @system_actor | Move to Control Plane |
| `elixir/web-ng/lib/serviceradar_web_ng/edge/onboarding_packages.ex` | system_actor() + authorize?: false | Require explicit actor |
| `elixir/web-ng/lib/serviceradar_web_ng/edge/onboarding_events.ex` | authorize?: false | Require explicit actor |
| `elixir/web-ng/lib/serviceradar_web_ng/accounts/scope.ex:42,52` | Tenant/membership queries | JWT-based context |
| `elixir/web-ng/.../plugs/tenant_context.ex` | Tenant resolution | Move to Control Plane |
| `elixir/web-ng/.../plugs/api_auth.ex` | Token validation | JWT-based |
| Multiple LiveView modules | Ad-hoc authorize?: false | Require scope/actor |
| Multiple API controllers | Cross-tenant access | Require proper authorization |

#### Identity Resources Architecture

| Resource | Schema | Strategy | Notes |
|----------|--------|----------|-------|
| `Tenant` | public | None (global) | Stays in Control Plane |
| `TenantMembership` | public | attribute + global?: true | **Move to Control Plane** |
| `User` | tenant_* | context (schema-based) | **Problematic**: Users per-tenant schema |
| `Token` | tenant_* | context | Stays with User |
| `ApiToken` | tenant_* | context | Tenant-scoped |

**Key Issue**: User is schema-isolated but TenantMembership is attribute-based in public schema. This hybrid approach creates complexity.

#### God Mode Patterns (Cross-Tenant Access)

**GenServers requiring Control Plane access**:
1. `TenantRegistryLoader` - Loads all tenant slugs into ETS for routing
2. `PlatformTenantBootstrap` - Creates/validates platform tenant on startup
3. `OperatorBootstrap` - Sets up NATS operator infrastructure
4. `TenantLifecyclePublisher` - Publishes tenant events to NATS stream

**Workers requiring Control Plane access**:
1. `CreateAccountWorker` - Creates NATS accounts for tenants
2. `ProvisionLeafWorker` - Provisions NATS leaf servers
3. `ProvisionCollectorWorker` - Provisions collector packages

## Goals / Non-Goals

### Goals
- Clean separation between Control Plane (tenant management) and Tenant Runtime (data processing)
- Eliminate authorize?: false in production code
- Simplify OSS deployment to single-tenant without multi-tenancy overhead
- Enable per-tenant resource isolation (each tenant gets own pods)
- Use JWT-based authorization instead of TenantMembership lookups

### Non-Goals
- Migrate existing SaaS customers (this is architectural cleanup first)
- Change OCSF data schema
- Modify NATS/CNPG cluster architecture (shared infrastructure remains)

## Decisions

### Decision 1: Control Plane Separation

**What**: Use existing `serviceradar-web/` private repository for SaaS Control Plane code including:
- Signup and tenant creation UI
- Tenant provisioning and lifecycle management
- NATS account/user JWT generation
- CNPG schema provisioning
- `tenant-workload-operator` (moved from OSS repo)
- Control Plane API

**Repository structure**:
- `serviceradar/` (OSS) - Tenant runtime code (core-elx, web-ng)
- `serviceradar-web/` (private) - SaaS Control Plane

**Why**:
- OSS users don't need multi-tenant provisioning code
- Reduces attack surface in Tenant Instances
- Cleaner code separation
- Existing private repo already set up with Phoenix/LiveView

**Alternatives considered**:
- Feature flags in monorepo - rejected due to complexity
- Separate packages in same repo - rejected due to deployment complexity

### Decision 2: JWT-Based Authorization

**What**: Tenant Instances derive authorization from JWT claims instead of TenantMembership lookups.

JWT structure:
```json
{
  "sub": "user-uuid",
  "tenant_id": "tenant-uuid",
  "role": "admin|operator|viewer",
  "iss": "serviceradar-control-plane",
  "exp": 1234567890
}
```

**Why**:
- Eliminates need for TenantMembership table in Tenant Instance
- Stateless authorization (no cross-tenant database queries)
- Control Plane is single source of truth for membership

**Migration path**:
1. Control Plane issues JWTs with membership claims
2. Tenant Instance trusts JWT signature
3. Remove TenantMembership from Tenant Instance codebase

### Decision 3: Single-Tenant OSS Mode

**What**: OSS deployment runs as single-tenant with:
- No tenant selection UI
- Default "platform" tenant auto-created
- Helm bootstrap job initializes system

**Why**:
- Simpler deployment for OSS users
- Same codebase, different configuration
- No need to understand multi-tenancy

### Decision 4: Remove Platform-Admin Role

**What**: Remove any platform-admin role from tenant instances. Platform
operations are handled exclusively by the Control Plane.

**Why**:
- Platform-admin bypasses all policies - security risk
- Instance code should only need :admin/:operator/:viewer/:system
- Platform operations belong in Control Plane services

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Breaking changes for existing deployments | Phased rollout, backward compat period |
| JWT token expiry during long operations | Refresh token mechanism, reasonable expiry |
| Increased pod count per tenant | Resource limits, horizontal pod autoscaling |
| CNPG connection pool exhaustion | Per-tenant connection limits, PgBouncer |

## Migration Plan

### Phase 1: Cleanup (In-place)
1. Remove authorize?: false from web-ng production code
2. Remove hardcoded system_actor definitions (use core's SystemActor)
3. Audit and categorize all SystemActor.platform() calls
4. Add proper actor context to all Ash operations

### Phase 2: Separation
1. Create serviceradar-saas repository
2. Move tenant-workload-operator
3. Implement Control Plane API
4. JWT generation and validation

### Phase 3: Tenant Instance Simplification
1. Remove cross-tenant code from core-elx and web-ng
2. Make tenant context required (no fallbacks)
3. Remove TenantMembership from Tenant Instance
4. JWT-based authorization

### Phase 4: Deployment Updates
1. Helm chart split (OSS vs SaaS)
2. Platform bootstrap job
3. Per-tenant deployment templates

## Open Questions

1. **User Identity**: With users per-tenant schema, how do we handle:
   - User wanting to switch tenants in UI?
   - Magic link email for user who exists in multiple tenants?

   **Potential answer**: Control Plane maintains global user registry, issues tenant-specific JWTs.

2. **Session Management**: How long should JWT tokens last? Refresh mechanism?

3. **Audit Trail**: Where do audit logs for cross-tenant operations live?

4. **Metrics Aggregation**: How do platform admins view metrics across tenants without God Mode?
