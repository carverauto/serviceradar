# Change: Break out Tenant/SaaS Control Plane

**Status: COMPLETE** (as of 2026-01-16)

This proposal has been implemented through multiple follow-on changes:
- `remove-tenant-awareness-from-instance` - Removed multi-tenant code from tenant instance
- `fix-authorize-bypass-security-debt` - Removed authorize?: false usage
- Control Plane moved to private `serviceradar-web` repository
- Tenant instance now uses single-tenant-per-deployment architecture

## Why
The current architecture conflates the SaaS control plane with the tenant runtime, leading to complexity in `core-elx` where it possesses "super power" access over the entire database. This violates strict tenant isolation boundaries and complicates the codebase with mixed multi-tenant logic.

### North Star Goal
**The OSS `serviceradar/` repo must always be deployable as a clean, working single-tenant system via `helm install` or `docker compose up` with zero Control Plane dependencies.**

By breaking out the control plane, we ensure that:
1.  **Clean OSS Experience:** `helm install serviceradar` gives you a fully working single-tenant system, no SaaS code involved.
2.  **Strict Isolation:** In SaaS mode, every tenant gets their own `core-elx` and `web-ng` instance managed by the Control Plane.
3.  **Reduced Complexity:** `core-elx` no longer needs complex multi-tenant policies; it only sees its own tenant's data.
4.  **Security:** Tenants connect to shared resources (NATS, CNPG) using restricted credentials (JWTs) that only allow access to their specific scope.
5.  **Independent Development:** Control Plane (`serviceradar-web/`) can be developed, tested, and deployed completely separately from the OSS stack.

## What Changes

### Architecture: Identical Deployments

**Key insight**: A Tenant Instance is the same deployment whether OSS or SaaS-managed. The Control Plane only provisions and scales - it doesn't change the tenant code.

- **Tenant Instance** (`serviceradar/` OSS repo): The standard deployment.
    - `core-elx`, `web-ng`, checkers, agents
    - Connects to NATS with its credentials
    - Connects to CNPG with its credentials (restricted to its schema)
    - **Identical** whether single-tenant OSS or one of many in SaaS

- **Control Plane** (`serviceradar-web/` private repo): Orchestrator for horizontal scaling.
    - Creates CNPG users + schemas
    - Creates NATS accounts
    - Deploys/scales Tenant Instances (via tenant-workload-operator)
    - Signup UI, billing, tenant management
    - Does *not* modify tenant instance code

- **Shared Infrastructure** (SaaS only):
    - **NATS**: Single cluster, tenant isolation via Account/User JWTs
    - **CNPG**: Single cluster, tenant isolation via PostgreSQL users/schemas

### Identity & Membership (Control Plane)
- **Centralized Authority**: `Tenant`, `User`, and `TenantMembership` resources move exclusively to the **Control Plane**.
- **TenantMembership Strategy**:
    - The "Attribute-based" multitenancy strategy for `TenantMembership` is removed from the Tenant Instance code.
    - Authorization is derived from **JWT Claims** issued by the Control Plane.
    - The Tenant Instance (`core-elx`) trusts the JWT signature and roles (e.g., `role: admin`, `tenant_id: <uuid>`) without needing to query a local `TenantMembership` table.
- **System Actor Elimination**:
    - The `system_actor` bypass (God Mode) is deprecated.
    - Internal background jobs (e.g., `Edge.Workers`) must operate within a specific Tenant Context, using a service account or specific token for that tenant, rather than a global superuser.
    - Refactor `ServiceRadarWebNG.Infrastructure` to remove "no actor" fallbacks. Explicit authorization is required for every call.

### Codebase Refactoring (`core-elx` & `web-ng`)
- **Ash Multitenancy**:
    - Remove "attribute-based" multitenancy logic where it bleeds across boundaries.
    - Standardize on `strategy :context` (Schema-based) but strictly enforced by the DB connection/role, not just application logic.
    - Audit and refactor `ServiceRadarWebNG.Infrastructure` and `AshTenant` to remove "system actor" bypasses and enforce strict scope usage.
- **Dependency Cleanup**:
    - Identify and sever links where `web-ng` or `core-elx` assumes it can access "all tenants".

## Impact
- **Specs**: Overrides or supersedes parts of `enforce-tenant-schema-isolation` by taking it to a full architectural split.
- **Code**: Significant refactoring in `elixir/serviceradar_core` and `web-ng`.
- **Ops**: Deployment model changes. Kubernetes manifests will need to support deploying "Tenant Stacks" dynamically or templated.

### Standalone & Helm Support (Single Tenant)
To ensure the OSS/Standalone version remains easy to deploy (zero-touch), we will introduce a **Platform Bootstrap** mechanism within the Helm chart.
- **Goal**: Automatically provision the environment for a single "Platform Tenant" without requiring an external Control Plane UI.
- **Mechanism**: A Helm `post-install` / `post-upgrade` Job (or a dedicated bootstrap container).
- **Bootstrap Actions**:
    1.  **Initialize Identity**: Create the default "Platform Tenant" and the initial Admin User (credentials via Secret/Values).
    2.  **Provision Resources**: Call the Control Plane APIs (or internal logic) to provision the NATS account and CNPG schema for this default tenant.
    3.  **Configure Runtime**: Inject the generated Tenant ID and Keys into the `web-ng` and `core-elx` configuration, effectively "pinning" them to this single tenant.
- **Outcome**: The user runs `helm install`, and the system boots up fully configured as a single-tenant instance of the multi-tenant architecture.

### Deep Dive Findings (Completed)

#### authorize?: false Usage in Production Code

The deep dive identified **30+ locations** in web-ng production code using `authorize?: false`:

| Category | Count | Examples |
|----------|-------|----------|
| Context modules (Inventory, Infrastructure) | 2 | Hardcoded system_actor + authorize?: false fallback |
| Scope/Auth (TenantResolver, Scope, Plugs) | 6 | Cross-tenant queries for tenant resolution |
| Edge modules (Onboarding*) | 4 | Tenant lookup and package operations |
| LiveView modules | 15+ | Ad-hoc authorization bypasses |
| API controllers | 10+ | Device, NATS, Edge, Collector APIs |

#### Duplicate system_actor Definitions

web-ng has **6 different system_actor definitions** that don't use the core's `ServiceRadar.Actors.SystemActor`:
- `inventory.ex:124-129`
- `infrastructure.ex:139-145`
- `tenant_resolver.ex:9-15` (module attribute)
- `edge/onboarding_packages.ex:274-280`
- `edge/onboarding_events.ex:126-132`
- `edge/workers/expire_packages_worker.ex:76-82`

#### God Mode GenServers

These components iterate ALL tenants and require Control Plane access:
- `TenantRegistryLoader` - Loads all tenant slugs for routing
- `PlatformTenantBootstrap` - Creates/validates platform tenant
- `OperatorBootstrap` - Sets up NATS operator infrastructure
- Various seeders (template, rule, zen_rule, sysmon_profile)

#### Identity Architecture Complexity

Current state:
| Resource | Schema | Strategy | Notes |
|----------|--------|----------|-------|
| Tenant | public | None (global) | Control Plane resource |
| TenantMembership | public | attribute + global?: true | **Hybrid** - queries from tenant code |
| User | tenant_* | context (schema-based) | Per-tenant user isolation |

**Problem**: Users are schema-isolated but memberships are in public schema. This creates cross-tenant queries during authentication.

### Implementation Plan

**Phase 1: Code Cleanup** (Can start immediately)
1. Remove all `authorize?: false` from web-ng production code
2. Consolidate system_actor definitions to use `ServiceRadar.Actors.SystemActor`
3. Make tenant context required (no nil fallbacks)

**Phase 2: Control Plane Separation**
1. Create `serviceradar-saas` repository
2. Move tenant-workload-operator
3. Extract tenant lifecycle management (TenantRegistryLoader, PlatformTenantBootstrap)
4. Move NATS provisioning (OperatorBootstrap, CreateAccountWorker)

**Phase 3: JWT-Based Authorization**
1. Define JWT claim structure for tenant context
2. Implement JWT generation in Control Plane
3. Update Tenant Instance to derive authorization from JWT claims
4. Remove TenantMembership queries from web-ng

**Phase 4: Helm/Deployment**
1. Create OSS single-tenant Helm chart (simplified)
2. Create SaaS multi-tenant Helm chart with Control Plane
3. Platform bootstrap job for OSS deployments

## Open Questions

### Resolved
- **Q**: Where are the "God Mode" code paths?
  **A**: Identified in TenantRegistryLoader, PlatformTenantBootstrap, OperatorBootstrap, various seeders, and 30+ authorize?: false locations in web-ng.

- **Q**: What needs to move to Control Plane?
  **A**: Tenant/TenantMembership management, NATS provisioning, tenant lifecycle events, platform bootstrap logic.

### Remaining
1. **User Identity Across Tenants**: With users in per-tenant schemas, how do we handle:
   - Magic link email for user who exists in multiple tenants?
   - User switching between tenants in UI?

   **Proposed Answer**: Control Plane maintains global user registry, issues tenant-specific JWTs. Tenant Instance trusts JWT claims.

2. **Platform Admin Access**: How do platform admins view metrics across tenants?
   **Proposed Answer**: Control Plane API with aggregation endpoints, not "super user" in tenant app.

3. **Session/JWT Management**: Token expiry, refresh mechanism, long-running operations?

4. **Migration Path**: How do existing SaaS customers transition?
