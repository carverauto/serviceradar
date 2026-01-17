# Design: Remove Tenant Awareness from Tenant Instance

## Context

### SaaS Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        Control Plane (serviceradar-web)                 │
│  - Account provisioning, billing, signup                                │
│  - Creates CNPG users/schemas, NATS accounts                           │
│  - Deploys per-account stacks in tenant namespaces                     │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                    ┌───────────────┼───────────────┐
                    ▼               ▼               ▼
         ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
         │  Account A   │  │  Account B   │  │  Account C   │
         │  Pods:       │  │  Pods:       │  │  Pods:       │
         │  - core-elx  │  │  - core-elx  │  │  - core-elx  │
         │  - web-ng    │  │  - web-ng    │  │  - web-ng    │
         │  - gateway   │  │  - gateway   │  │  - gateway   │
         │  - zen       │  │  - zen       │  │  - zen       │
         └──────┬───────┘  └──────┬───────┘  └──────┬───────┘
                │                 │                 │
                │    (scoped credentials/JWTs)     │
                ▼                 ▼                 ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                        Shared Infrastructure                            │
│  ┌─────────────────────────────┐  ┌─────────────────────────────────┐  │
│  │  CNPG (PostgreSQL)          │  │  NATS                           │  │
│  │  - account_a schema         │  │  - Account A (JWT isolated)     │  │
│  │  - account_b schema         │  │  - Account B (JWT isolated)     │  │
│  │  - account_c schema         │  │  - Account C (JWT isolated)     │  │
│  │  (isolated by DB user)      │  │  (isolated by account JWT)      │  │
│  └─────────────────────────────┘  └─────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
```

**Key Points:**
- Each account gets its **own pods** (core-elx, web-ng, agent-gateway, zen)
- **CNPG is shared** - isolation via schema-scoped PostgreSQL users
- **NATS is shared** - isolation via account-scoped JWT accounts
- **Instance pods don't know about other accounts** - credentials only allow their data

ServiceRadar uses PostgreSQL schema-based isolation where each account has its own schema (e.g., `account_abc123`). Currently, the application code maintains tenant awareness by:

1. Passing `tenant: schema` to every Ash query
2. Using `SystemActor.for_tenant(tenant_id, :component)` for scoped operations
3. Tracking tenant context through `Scope` structs in the request lifecycle

This design document outlines how to eliminate tenant awareness from the Tenant Instance, making isolation database-enforced rather than application-enforced.

## Goals

- **Simplify application code** - No tenant tracking, no `tenant:` params
- **DB-enforced isolation** - Impossible to access other tenants' data
- **Same code for OSS/SaaS** - Single codebase works for both deployment modes
- **Secure by default** - Can't accidentally leak data across tenants

## Non-Goals

- Changing the Control Plane architecture (it still needs multi-tenant access)
- Modifying the NATS tenant isolation (already JWT-based)
- Changing the frontend UX (tenant switcher removal is separate)

## Decisions

### Decision 1: Schema-Scoped PostgreSQL Users

Each deployment instance connects to PostgreSQL with credentials that only have access to its schema.

**Implementation:**

```sql
-- Control Plane creates this for each account
CREATE USER account_abc123_app WITH PASSWORD 'generated-secret';

-- Grant access only to account schema
GRANT USAGE ON SCHEMA account_abc123 TO account_abc123_app;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA account_abc123 TO account_abc123_app;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA account_abc123 TO account_abc123_app;

-- Set default search path
ALTER USER account_abc123_app SET search_path TO account_abc123;

-- Revoke access to other schemas (explicit, though USAGE not granted anyway)
REVOKE ALL ON SCHEMA public FROM account_abc123_app;
```

**Connection String:**
```
postgresql://account_abc123_app:secret@cnpg-cluster:5432/serviceradar?search_path=account_abc123
```

**Alternatives Considered:**
- Row-Level Security (RLS): More complex, still requires tenant_id tracking in app
- Separate databases per account: Higher operational overhead, harder to share resources

### Decision 2: Remove Multitenancy from Ash Resources

Current resources have:
```elixir
postgres do
  table "devices"
  repo ServiceRadar.Repo
end

multitenancy do
  strategy :context
  attribute :tenant_id
end
```

Target resources have:
```elixir
postgres do
  table "devices"
  repo ServiceRadar.Repo
  # No schema specified - uses connection's search_path
end

# No multitenancy block at all
```

**Why This Works:**
- PostgreSQL's `search_path` determines which schema is used for unqualified table names
- When app connects as `account_abc123_app` with `search_path=account_abc123`, all queries go to that schema
- Ash doesn't need to know about tenants - it's transparent

### Decision 3: Simplify Actor Model

**Current Actors:**
```elixir
# Tenant-scoped system actor
actor = SystemActor.for_tenant(tenant_id, :my_worker)
Ash.read!(query, actor: actor, tenant: schema)
```

**Target Actors:**
```elixir
# System actor for background jobs (no tenant context needed)
actor = SystemActor.system(:my_worker)
Ash.read!(query, actor: actor)  # Uses connection's schema

# User actor from JWT
actor = %{id: user_id, role: role, email: email}
Ash.read!(query, actor: actor)  # Uses connection's schema
```

**Actor Structure:**
```elixir
# User actor (from JWT or session)
%{
  id: "user-uuid",
  role: :admin | :operator | :viewer,
  email: "user@example.com"
}

# System actor (for background jobs)
%{
  id: "system:worker_name",
  role: :system,
  component: "worker_name"
}
```

No `tenant_id` in actors - it's implicit from the database connection.

### Decision 4: Handle Shared/Global Resources

Some resources currently live in the `public` schema and are accessed across tenants:
- `tenants` - Tenant metadata
- `nats_operators` - NATS operator config
- `nats_platform_tokens` - Platform NATS tokens

**Options:**

1. **Move to Control Plane only** - Tenant instance doesn't need these
2. **Replicate to tenant schema** - Copy needed config at provisioning time
3. **Read-only access to public** - Grant SELECT on specific tables

**Decision:** Option 1 for most, Option 2 for essential config.

- `tenants` table: Not needed in tenant instance. Tenant info comes from config/JWT.
- `nats_operators`: Tenant doesn't manage operators. NATS creds come from Control Plane.
- Tenant-specific config: Stored in tenant schema at provisioning time.

### Decision 5: OSS Single-Tenant Mode

For OSS deployments, there's one account. Two options:

1. **Use a default schema** - Same as today but simplified
2. **Use "public" schema directly** - No dedicated schema at all

**Decision:** Option 1 - Use a default schema (e.g., `account_platform`).

- Helm bootstrap job creates the schema and user
- Connection uses `account_platform` search_path
- Code is identical to SaaS tenant instance
- Easy to migrate OSS to SaaS later (just change credentials)

## Database Schema Changes

### Resources That Keep tenant_id Column

None. The `tenant_id` column becomes unnecessary when using schema-based isolation with scoped credentials.

**Before:**
```sql
CREATE TABLE account_abc.devices (
  id UUID PRIMARY KEY,
  tenant_id UUID NOT NULL,  -- Redundant!
  name TEXT,
  ...
);
```

**After:**
```sql
CREATE TABLE account_abc.devices (
  id UUID PRIMARY KEY,
-- No tenant_id needed - table is in account schema
  name TEXT,
  ...
);
```

### Migration for Existing Schemas

```sql
-- For each account schema, drop the tenant_id column
ALTER TABLE account_abc.devices DROP COLUMN tenant_id;
ALTER TABLE account_abc.agents DROP COLUMN tenant_id;
-- etc.
```

This is a **BREAKING** change for any external tools that rely on `tenant_id`.

## Risks / Trade-offs

### Risk: Cross-Tenant Queries Become Impossible

**Mitigation:** This is the goal. Any legitimate cross-tenant operation belongs in the Control Plane.

### Risk: Migration Complexity for Existing SaaS

**Mitigation:**
1. Create new schema-scoped users first
2. Deploy new instances with new credentials
3. Old instances continue working until cutover
4. Controlled migration per tenant

### Risk: Debugging Harder Without Tenant Context

**Mitigation:**
- Tenant ID still available in JWT claims
- Logs can include tenant from config/environment
- Database user name includes tenant ID

### Trade-off: More Database Users

Creating a PostgreSQL user per account increases DB overhead slightly.

**Mitigation:** PostgreSQL handles thousands of users efficiently. CNPG can manage user secrets via K8s.

## Migration Plan

### Phase 1: Remove Tenant-Aware Code

1. Delete `TenantSchemas` module
2. Simplify `SystemActor` module
3. Remove `tenant:` parameters from all call sites
4. Delete `find_*_across_tenants()` functions
5. Remove `Scope.tenant_id()` usage

### Phase 2: Control Plane Credential Provisioning

1. Create schema-scoped users per account
2. Store credentials in K8s secrets
3. Inject credentials via control plane deployment tooling
4. Test with single deployment

### Phase 3: Infrastructure Cleanup

1. Remove tenant-scoped cert generation and CA hierarchy
2. Update Helm/Compose config to drop tenant fields
3. Remove tenant-workload-operator artifacts from this repo

### Phase 4: Schema Cleanup

1. Remove `tenant_id` attributes where redundant
2. Generate migrations to drop `tenant_id` columns
3. Update policies to not reference tenant_id

### Phase 5: Documentation + Archive

1. Update deployment docs
2. Archive related OpenSpec changes

## Rollback Plan

If issues arise:
1. Redeploy with old credentials (superuser)
2. Deploy previous release of the tenant-aware code
3. Old code paths still work

Keep both code paths available for one release cycle.

## Open Questions

1. **CNPG User Management**: How does CNPG handle many users? Is there a limit?

2. **Connection Pooling**: Does PgBouncer work with schema-scoped users?

3. **Monitoring**: How do we monitor per-tenant database usage with separate users?

4. **Secrets Rotation**: How do we rotate tenant database credentials?
