# Change: Remove Account Awareness from Instance

## Why

The current ServiceRadar instance codebase (`web-ng`, `core-elx`) is deeply multi-account aware despite the architectural goal of having each instance only see its own data. This creates several problems:

1. **Security by Convention, Not Enforcement**: Schema isolation relies on application code correctly passing schema context to every Ash query. A single missed parameter could leak data.

2. **Complexity Overhead**: Every controller, LiveView, and worker must track schema context, use cross-schema system actors, and pass schema context to queries.

3. **God Mode Still Exists**: Cross-schema helper functions iterate ALL schemas. This capability shouldn't exist in an instance.

4. **Architectural Violation**: The proposal 2286-break-out-tenant-control-plane explicitly stated:
   > "Connects to CNPG with its credentials (restricted to its schema)"
   > "core-elx no longer needs complex multi-account policies; it only sees its own data"

   This was not implemented. We cleaned up `authorize?: false` but replaced it with `SystemActor` patterns that still allow cross-schema access.

### Relationship to 2286-break-out-tenant-control-plane

This proposal completes the architectural vision of #2286 that was not fully realized. While #2286 moved Control Plane components to `serviceradar-web/` and added JWT-based auth, it did not:
- Remove account awareness from the instance code
- Configure schema-scoped database credentials
- Eliminate cross-schema query capabilities

This proposal finishes that work.

## What Changes

### Database Connection: Schema-Scoped Credentials

**Current State:**
```
┌─────────────────────────────────────────────────┐
│              Instance App                       │
│  DB credentials: serviceradar (superuser)       │
│  Can see: ALL schemas                           │
│  Must track: schema context everywhere          │
└─────────────────────────────────────────────────┘
         ↓
┌─────────────────────────────────────────────────┐
│     PostgreSQL                                  │
│  account_abc │ account_def │ account_xyz │ public │
│  ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^       │
│  (all visible to app)                           │
└─────────────────────────────────────────────────┘
```

**Target State:**
```
┌─────────────────────────────────────────────────┐
│              Instance App                       │
│  DB credentials: account_abc_app                │
│  Can see: account_abc schema ONLY               │
│  Tracks: nothing - implicit isolation           │
└─────────────────────────────────────────────────┘
         ↓
┌─────────────────────────────────────────────────┐
│     PostgreSQL                                  │
│  [account_abc] │ account_def │ account_xyz │ public │
│   (visible)   │  (hidden)  │  (hidden)  │       │
└─────────────────────────────────────────────────┘
```

### Code Changes

1. **Remove schema context from all Ash operations**
   - No more explicit schema context options
   - Just `Ash.read!(query, actor: actor)` - schema is implicit

2. **Remove schema enumeration helpers**
   - Delete any schema listing calls
   - Delete schema lookup helpers
   - No concept of "other schemas" exists

3. **Simplify `SystemActor`**
   - Remove cross-schema system actor helpers
   - Keep simple `SystemActor.system()` for background jobs

4. **Remove multitenancy config from Ash resources**
   - Remove `multitenancy strategy: :context` from resources
   - Remove `multitenancy strategy: :attribute` from resources
   - Tables live in the schema, no account_id column needed

5. **Remove account registry resource from instance**
   - Instance does not query a global account table
   - Instance metadata comes from config/JWT only

6. **Remove cross-schema code paths**
   - Delete any cross-schema package lookup
   - Simplify or remove registry loaders
   - Any code that iterates schemas - delete

### Control Plane Responsibility

The **Control Plane** (`serviceradar-web/`) becomes responsible for:
- Creating PostgreSQL users with schema-scoped privileges
- Setting `search_path` in connection strings
- Managing the account registry (global view of all accounts)
- Cross-account operations (admin dashboards, billing, etc.)

## Impact

### Affected Code

| Component | Changes |
|-----------|---------|
| `web-ng/` controllers | Remove schema context params, simplify actors |
| `web-ng/` LiveViews | Remove schema context tracking |
| `core-elx/` workers | Remove cross-schema actor patterns |
| Ash resources | Remove multitenancy configuration |
| `TenantSchemas` | Delete or move to Control Plane |
| `SystemActor` | Simplify to single system actor |
| Database config | Schema-scoped credentials |

### Affected Specs

- `enforce-tenant-schema-isolation` - Superseded by DB-enforced isolation
- Control plane provisioning (serviceradar-web) creates scoped credentials
- `2286-break-out-tenant-control-plane` - This completes that vision

### **BREAKING** Changes

1. **Database credentials must be schema-scoped** - Existing deployments need credential rotation
2. **Instance cannot access other accounts** - By design
3. **`SystemActor.platform()` removed** - No replacement in instance code
4. **Schema enumeration helpers removed** - No replacement in instance code

### Migration Path

1. **OSS (Single Deployment)**: No migration needed - already one schema
2. **SaaS (Multi-Account)**: Control Plane must:
   - Create per-account PostgreSQL users
   - Update instance connection strings
   - Deploy instances with scoped credentials

## Open Questions

1. **Shared Tables**: Some tables might need to be in `public` schema (e.g., `nats_operators`). How do we handle read-only access to shared config?

   **Proposed**: Grant SELECT on specific public tables, or replicate needed config into account schema.

2. **OSS account metadata**: Does the OSS deployment need a record in a registry, or can it be purely config-based?

   **Proposed**: Config-based. Account ID comes from environment variable or is hard-coded.

3. **Gradual Migration**: Can we do this incrementally, or is it all-or-nothing?

   **Proposed**: Incremental - remove schema context params first (while still using same credentials), then switch to scoped credentials.
