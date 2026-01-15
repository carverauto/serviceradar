# Change: Remove Tenant Awareness from Tenant Instance

## Why

The current Tenant Instance codebase (`web-ng`, `core-elx`) is deeply tenant-aware despite the architectural goal of having each instance only see its own data. This creates several problems:

1. **Security by Convention, Not Enforcement**: Tenant isolation relies on application code correctly passing `tenant:` parameters to every Ash query. A single missed parameter could leak data.

2. **Complexity Overhead**: Every controller, LiveView, and worker must track tenant context, use `SystemActor.for_tenant()` or `SystemActor.platform()`, and pass `tenant:` to queries.

3. **God Mode Still Exists**: Functions like `find_package_across_tenants()` iterate ALL tenant schemas using `TenantSchemas.list_schemas()`. This capability shouldn't exist in a tenant instance.

4. **Architectural Violation**: The proposal 2286-break-out-tenant-control-plane explicitly stated:
   > "Connects to CNPG with its credentials (restricted to its schema)"
   > "core-elx no longer needs complex multi-tenant policies; it only sees its own tenant's data"

   This was not implemented. We cleaned up `authorize?: false` but replaced it with `SystemActor` patterns that still allow cross-tenant access.

### Relationship to 2286-break-out-tenant-control-plane

This proposal completes the architectural vision of #2286 that was not fully realized. While #2286 moved Control Plane components to `serviceradar-web/` and added JWT-based auth, it did not:
- Remove tenant awareness from the instance code
- Configure schema-scoped database credentials
- Eliminate cross-tenant query capabilities

This proposal finishes that work.

## What Changes

### Database Connection: Schema-Scoped Credentials

**Current State:**
```
┌─────────────────────────────────────────────────┐
│              Tenant Instance App                │
│  DB credentials: serviceradar (superuser)       │
│  Can see: ALL schemas                           │
│  Must track: tenant context everywhere          │
└─────────────────────────────────────────────────┘
         ↓
┌─────────────────────────────────────────────────┐
│     PostgreSQL                                  │
│  tenant_abc │ tenant_def │ tenant_xyz │ public  │
│  ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^       │
│  (all visible to app)                           │
└─────────────────────────────────────────────────┘
```

**Target State:**
```
┌─────────────────────────────────────────────────┐
│              Tenant Instance App                │
│  DB credentials: tenant_abc_app                 │
│  Can see: tenant_abc schema ONLY                │
│  Tracks: nothing - implicit isolation           │
└─────────────────────────────────────────────────┘
         ↓
┌─────────────────────────────────────────────────┐
│     PostgreSQL                                  │
│  [tenant_abc] │ tenant_def │ tenant_xyz │ public│
│   (visible)   │  (hidden)  │  (hidden)  │       │
└─────────────────────────────────────────────────┘
```

### Code Changes

1. **Remove `tenant:` parameter from all Ash operations**
   - No more `Ash.read!(query, actor: actor, tenant: schema)`
   - Just `Ash.read!(query, actor: actor)` - schema is implicit

2. **Remove `TenantSchemas` module usage**
   - Delete `TenantSchemas.list_schemas()` calls
   - Delete `TenantSchemas.schema_for_id()` calls
   - No concept of "other schemas" exists

3. **Simplify `SystemActor`**
   - Remove `SystemActor.platform()` - no cross-tenant ops
   - Remove `SystemActor.for_tenant()` - tenant is implicit
   - Keep simple `SystemActor.system()` for background jobs

4. **Remove multitenancy config from Ash resources**
   - Remove `multitenancy strategy: :context` from resources
   - Remove `multitenancy strategy: :attribute` from resources
   - Tables live in the schema, no tenant_id column needed

5. **Simplify `Tenant` resource**
   - In tenant instance: single row representing "self"
   - Or remove entirely - tenant info comes from config/JWT

6. **Remove cross-tenant code paths**
   - `find_package_across_tenants()` - delete
   - `TenantRegistryLoader` - simplify or remove
   - Any code that iterates tenants - delete

### Control Plane Responsibility

The **Control Plane** (`serviceradar-web/`) becomes responsible for:
- Creating PostgreSQL users with schema-scoped privileges
- Setting `search_path` in connection strings
- Managing the `Tenant` table (global view of all tenants)
- Cross-tenant operations (admin dashboards, billing, etc.)

## Impact

### Affected Code

| Component | Changes |
|-----------|---------|
| `web-ng/` controllers | Remove `tenant:` params, simplify actors |
| `web-ng/` LiveViews | Remove tenant context tracking |
| `core-elx/` workers | Remove `for_tenant()` patterns |
| Ash resources | Remove multitenancy configuration |
| `TenantSchemas` | Delete or move to Control Plane |
| `SystemActor` | Simplify to single system actor |
| Database config | Schema-scoped credentials |

### Affected Specs

- `enforce-tenant-schema-isolation` - Superseded by DB-enforced isolation
- `add-tenant-workload-operator` - Control Plane creates scoped credentials
- `2286-break-out-tenant-control-plane` - This completes that vision

### **BREAKING** Changes

1. **Database credentials must be schema-scoped** - Existing deployments need credential rotation
2. **Tenant Instance cannot access other tenants** - By design
3. **`SystemActor.platform()` removed** - No replacement in tenant instance
4. **`TenantSchemas` module removed** - No replacement in tenant instance

### Migration Path

1. **OSS (Single-Tenant)**: No migration needed - already one tenant
2. **SaaS (Multi-Tenant)**: Control Plane must:
   - Create per-tenant PostgreSQL users
   - Update tenant instance connection strings
   - Deploy instances with scoped credentials

## Open Questions

1. **Shared Tables**: Some tables might need to be in `public` schema (e.g., `nats_operators`). How do we handle read-only access to shared config?

   **Proposed**: Grant SELECT on specific public tables, or replicate needed config into tenant schema.

2. **Platform Tenant in OSS**: Does the OSS deployment still need a "Tenant" record, or can it be purely config-based?

   **Proposed**: Config-based. Tenant ID comes from environment variable or is hard-coded.

3. **Gradual Migration**: Can we do this incrementally, or is it all-or-nothing?

   **Proposed**: Incremental - remove `tenant:` params first (while still using same credentials), then switch to scoped credentials.
