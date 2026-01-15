# Tasks: Remove Tenant Awareness from Tenant Instance

## Summary

Make tenant instance code (web-ng, core-elx) completely tenant-unaware by:
1. Using schema-scoped CNPG credentials (DB enforces isolation)
2. Using tenant-scoped NATS JWTs (NATS enforces isolation)
3. Removing all `tenant:` parameters from Ash queries
4. Removing cross-tenant code paths entirely

---

## Phase 1: Control Plane - CNPG User Provisioning

### 1.1 Create CNPG user provisioning in Control Plane

- [x] **1.1.1 Add CNPG user creation to tenant provisioning flow**
  - Created `CNPG.Provisioner` module for PostgreSQL user/schema management
  - Created `CreateCnpgUserWorker` Oban worker for async provisioning
  - Creates PostgreSQL user: `tenant_{slug}_app`
  - Grants: USAGE on tenant schema, ALL on tables/sequences
  - Sets: `search_path` to tenant schema
  - Stores: credentials in K8s secret via `K8s.SecretManager`

- [x] **1.1.2 Create migration to add CNPG fields to Tenant resource**
  - Added `cnpg_username` and `cnpg_password_secret_ref` to Tenant resource
  - Created migration `20260115100000_add_cnpg_user_fields.exs`
  - Updated `set_cnpg_ready` action to accept new fields

- [x] **1.1.3 Wire up tenant provisioning to create CNPG user**
  - Updated `TenantController.create/2` to enqueue `CreateCnpgUserWorker`
  - CNPG provisioning runs in parallel with NATS provisioning
  - Added `cnpg_provisioning` queue to Oban config

- [x] **1.1.4 Update tenant-workload-operator to inject CNPG credentials**
  - Added `TemplateCNPGCreds` struct with `enabled` and `envPrefix` fields
  - Updated `TenantWorkloadTemplate` CRD to include `cnpgCreds` field
  - Injects DB credentials as env vars: `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD`, `DB_NAME`, `DB_SCHEMA`, `DB_URL`
  - Uses `secretKeyRef` to reference K8s secret created by Control Plane

### 1.2 Test CNPG isolation

- [ ] **1.2.1 Create test tenant with scoped credentials**
- [ ] **1.2.2 Verify cannot access other tenant schemas**
- [ ] **1.2.3 Verify app works with scoped credentials**

---

## Phase 2: Remove Multitenancy from Ash Resources

### 2.1 Audit current multitenancy configuration

- [x] **2.1.1 List all resources with `multitenancy` blocks**
  - Found 59 resources with `strategy :context` (schema-isolated)
  - Found 1 resource with `strategy :attribute` + `global? true` (TenantMembership)
  - Found 4 resources with no multitenancy (Tenant, NatsOperator, NatsPlatformToken, NatsServiceAccount)

- [x] **2.1.2 List all resources with `tenant_id` attributes**
  - Found 47 resources with explicit `tenant_id` attributes
  - Most are redundant when using schema-based isolation

- [x] **2.1.3 Identify resources that should stay in public schema**
  - Tenant, TenantMembership, NatsOperator, NatsPlatformToken, NatsServiceAccount
  - These are Control Plane resources

### 2.2 Create feature flag for gradual migration

- [x] **2.2.1 Add `TENANT_AWARE_MODE` environment variable**
  - Created `ServiceRadar.Cluster.TenantMode` module
  - Provides `tenant_aware?/0`, `tenant_opts/1`, `with_tenant/2` helpers
  - Added `system_actor/2` and `ash_opts/3` convenience functions
  - Updated `runtime.exs` to read `TENANT_AWARE_MODE` env var

- [x] **2.2.2 Update Repo configuration**
  - Updated `ServiceRadar.Repo.all_tenants/0` to check tenant mode
  - In tenant-aware mode: returns all tenant schemas
  - In tenant-unaware mode: returns empty list (tenant is implicit)

- [x] **2.2.3 Add SystemActor.system/1 for tenant-unaware mode**
  - Added `system/1` function for simple system actors without tenant_id
  - Updated module docs to explain when to use each pattern

### 2.3 Remove multitenancy from resources (behind flag)

**Decision: Keep multitenancy DSL in resources**

After analysis, we determined that Ash resource definitions don't need to change:
- `multitenancy strategy: :context` tells AshPostgres to use schema prefix when `tenant:` is passed
- When `tenant:` is NOT passed, no prefix is set and PostgreSQL uses the connection's `search_path`
- In tenant-unaware mode, the CNPG credentials set `search_path` to the tenant schema

The actual work is in Phase 3: stop passing `tenant:` parameter when in tenant-unaware mode.

- [x] **2.3.1 Verify approach works with Ash**
  - Resources with `strategy :context` don't require `tenant:` parameter by default
  - When no tenant is passed, queries use connection's `search_path`
  - This means Phase 3 code changes are sufficient

- [x] **2.3.2 Document resources that need special handling**
  - Public schema resources (Tenant, TenantMembership, NatsOperator, etc.) stay unchanged
  - These are Control Plane resources and don't exist in tenant instances

- [N/A] **2.3.3-2.3.5 - Skipped**
  - No changes needed to Ash resource definitions
  - `tenant_id` attributes can be removed later as cleanup task

---

## Phase 3: Remove tenant: Parameter from Code

**Migration Guide**: See `migration-guide.md` for patterns and examples.

### 3.1 Update web-ng controllers

- [x] **3.1.1 api/collector_controller.ex** (EXAMPLE FILE)
  - Updated all Ash calls to use `TenantMode.ash_opts/3`
  - Updated `find_package_across_tenants()` to handle both modes
  - Platform operations use mode-conditional actors
  - Pattern: `opts = TenantMode.ash_opts(:component, tenant_id, schema)`

- [x] **3.1.2 api/edge_controller.ex**
  - Updated all Ash calls to use `TenantMode` helpers
  - Updated `find_package_across_tenants()` with mode check

- [x] **3.1.3 api/enroll_controller.ex**
  - Updated `mark_enrolled()` and `find_package_across_tenants()`
  - Uses mode-conditional actors

- [x] **3.1.4 api/nats_controller.ex** (Control Plane only)
  - No changes needed - manages NatsOperator/NatsPlatformToken in public schema

- [x] **3.1.5 auth_controller.ex**
  - Updated JWT token generation to use `TenantMode.tenant_opts/1`

- [x] **3.1.6 tenant_controller.ex** (Control Plane only)
  - No changes needed - handles multi-tenant switching (Control Plane feature)
  - `tenant: nil` is intentional for TenantMembership (attribute-based multitenancy)

### 3.2 Update web-ng LiveViews

**Audit Complete**: Found 16 LiveView files with ~50+ `tenant:` usages.

**Files requiring updates**:
- [ ] `device_live/index.ex` - 2 occurrences (create_single_device)
- [ ] `device_live/show.ex` - 4 occurrences
- [ ] `admin/edge_package_live/index.ex` - 12 occurrences (OnboardingPackages helper calls)
- [ ] `admin/integration_live/index.ex` - 7 occurrences
- [ ] `admin/collector_live/index.ex` - 4 occurrences
- [ ] `admin/edge_sites_live/index.ex` - 1 occurrence
- [ ] `admin/edge_sites_live/show.ex` - 2 occurrences
- [ ] `admin/job_live/index.ex` - struct field only (no changes needed)
- [ ] `admin/job_live/show.ex` - struct field only (no changes needed)
- [ ] `agent_live/index.ex` - struct field only (no changes needed)
- [ ] `agent_live/show.ex` - 1 occurrence
- [ ] `analytics_live/index.ex` - helper function (schema_for_scope)
- [ ] `log_live/index.ex` - helper function (schema_for_scope)
- [ ] `settings/rules_live/index.ex` - 1 occurrence
- [ ] `settings/cluster_live/index.ex` - struct field only (no changes needed)
- [ ] `infrastructure_live/index.ex` - struct field only (no changes needed)

**Pattern to apply** (same as controllers):
```elixir
# Before
actor = SystemActor.for_tenant(tenant_id, :component)
Ash.read(query, tenant: schema, actor: actor)

# After
opts = TenantMode.ash_opts(:component, tenant_id, schema)
Ash.read(query, opts)
```

**Helper module pattern** (OnboardingPackages, etc.):
```elixir
# Before
OnboardingPackages.list(filters, tenant: tenant)

# After
tenant_opts = TenantMode.tenant_opts(schema)
OnboardingPackages.list(filters, tenant_opts)
```

### 3.3 Update web-ng plugs and auth

- [x] **3.3.1 plugs/api_auth.ex**
  - Updated `find_api_token()` with TenantMode check (cross-tenant vs single-schema)
  - Updated `record_token_usage()` to use `TenantMode.ash_opts/3`
  - Updated `validate_ash_jwt()` to use mode-conditional actors
  - Removed redundant private `tenant_opts/1` helper

- [x] **3.3.2 plugs/tenant_context.ex**
  - Updated `load_tenant()` to use `TenantMode.system_actor/2`
  - Tenant resource is in public schema, no tenant: parameter needed

- [x] **3.3.3 accounts/scope.ex**
  - Updated `for_user()` to use `TenantMode.system_actor/2`
  - Updated `fetch_tenant_by_id()` to use mode-conditional actor
  - Removed `tenant: nil` (no longer needed with mode-conditional actors)

- [x] **3.3.4 user_auth.ex**
  - Updated `verify_token()` to use `TenantMode.tenant_opts/1`
  - Updated actor to use `TenantMode.system_actor/2`
  - Removed redundant private `tenant_opts/1` helper

### 3.4 Update core-elx workers

- [ ] **3.4.1 Audit all Oban workers for `tenant:` usage**

- [ ] **3.4.2 Update each worker**
  - Remove `SystemActor.for_tenant()` patterns
  - Use simple `SystemActor.system(:worker_name)`

### 3.5 Update core-elx GenServers

- [ ] **3.5.1 TenantRegistryLoader**
  - Remove or simplify - no need to load all tenant slugs
  - In tenant instance, there's only "self"

- [ ] **3.5.2 Other GenServers**
  - Audit for cross-tenant patterns
  - Remove or simplify

---

## Phase 4: Simplify SystemActor

### 4.1 Refactor SystemActor module

- [ ] **4.1.1 Remove `SystemActor.platform/1`**
  - No cross-tenant operations in tenant instance
  - Move any legitimate uses to Control Plane

- [ ] **4.1.2 Remove `SystemActor.for_tenant/2`**
  - Tenant is implicit from DB connection
  - Replace with `SystemActor.system/1`

- [ ] **4.1.3 Simplify to single system actor pattern**
  ```elixir
  def system(component) when is_atom(component) do
    %{
      id: "system:#{component}",
      role: :system,
      component: component
    }
  end
  ```

### 4.2 Update authorization policies

- [ ] **4.2.1 Update bypass policies**
  - Remove tenant_id checks from system actor bypass
  - Simplify to just role check

- [ ] **4.2.2 Remove platform actor policies**
  - No platform actor exists in tenant instance

---

## Phase 5: Delete Cross-Tenant Code

### 5.1 Remove TenantSchemas module usage

- [ ] **5.1.1 Find all `TenantSchemas.list_schemas()` calls**
  - Delete the calls entirely

- [ ] **5.1.2 Find all `TenantSchemas.schema_for_id()` calls**
  - Delete or replace with config lookup

- [ ] **5.1.3 Delete TenantSchemas module from tenant instance**
  - Or move to Control Plane only

### 5.2 Remove cross-tenant query functions

- [ ] **5.2.1 Delete `find_package_across_tenants()`**
  - In collector_controller.ex

- [ ] **5.2.2 Delete `find_api_token()` cross-tenant search**
  - In api_auth.ex - tokens are in current schema only

- [ ] **5.2.3 Audit for other cross-tenant patterns**
  - Search for `Enum.reduce_while.*TenantSchemas`

### 5.3 Remove Tenant resource from tenant instance

- [ ] **5.3.1 Decide: keep minimal Tenant or remove entirely?**
  - Option A: Single "self" record for tenant metadata
  - Option B: All tenant info from config/JWT

- [ ] **5.3.2 Implement chosen approach**

---

## Phase 6: OSS Single-Tenant Mode

### 6.1 Update Helm bootstrap for OSS

- [ ] **6.1.1 Create default tenant schema in bootstrap job**
  - Schema: `tenant_platform` (or configurable)
  - User: `tenant_platform_app`

- [ ] **6.1.2 Configure pods with scoped credentials**
  - Same pattern as SaaS, just one tenant

### 6.2 Test OSS deployment

- [ ] **6.2.1 `helm install` smoke test**
  - Verify system works with scoped credentials

- [ ] **6.2.2 Verify no cross-tenant code paths**
  - Check logs for any TenantSchemas usage

---

## Phase 7: Cleanup and Documentation

### 7.1 Remove feature flag

- [ ] **7.1.1 Remove `TENANT_AWARE_MODE` flag**
  - After all migrations complete

- [ ] **7.1.2 Remove old code paths**
  - Delete any `if tenant_aware_mode?()` branches

### 7.2 Update documentation

- [ ] **7.2.1 Update CLAUDE.md**
  - Remove multi-tenant patterns
  - Document simplified actor model

- [ ] **7.2.2 Update deployment docs**
  - Document CNPG credential requirements
  - Document OSS vs SaaS differences

### 7.3 Archive related proposals

- [ ] **7.3.1 Update 2286-break-out-tenant-control-plane**
  - Mark as complete with reference to this proposal

- [ ] **7.3.2 Archive enforce-tenant-schema-isolation**
  - Superseded by DB-enforced isolation

---

## Verification Checklist

Before marking complete:

- [ ] Tenant instance cannot query other tenant schemas
- [ ] No `tenant:` parameters in Ash calls
- [ ] No `TenantSchemas` usage in tenant instance
- [ ] No `SystemActor.platform()` usage in tenant instance
- [ ] OSS helm install works with scoped credentials
- [ ] SaaS tenant provisioning creates scoped credentials
- [ ] All tests pass with new architecture
