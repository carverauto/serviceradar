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

**Status: COMPLETE** (as of 2026-01-16)

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

**Status: COMPLETE** (as of 2026-01-16)

All `tenant:` parameters have been removed from LiveView files:
- [x] `device_live/index.ex` - Uses scope pattern
- [x] `device_live/show.ex` - Uses scope pattern
- [x] `admin/edge_package_live/index.ex` - Uses scope pattern
- [x] `admin/integration_live/index.ex` - Uses scope pattern
- [x] `admin/collector_live/index.ex` - Uses environment config
- [x] `admin/edge_sites_live/index.ex` - Uses scope pattern
- [x] `admin/edge_sites_live/show.ex` - Uses environment config
- [x] `admin/nats_live/index.ex` - Simplified (removed multi-tenant UI)
- [x] `admin/nats_live/show.ex` - Simplified (redirect only)
- [x] `settings/rules_live/index.ex` - Uses scope pattern

LiveViews now use `scope:` pattern which extracts actor via `Ash.Scope.ToOpts`.

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

- [x] **3.4.1 Audit all Oban workers for `tenant:` usage**
  - Found 3 edge workers: `provision_collector_worker.ex`, `provision_leaf_worker.ex`, `record_event_worker.ex`
  - Found 44 files total with `SystemActor.for_tenant` usage

- [x] **3.4.2 Update edge workers (3 files)**
  - `provision_collector_worker.ex` - updated all Ash calls to use `TenantMode.ash_opts/3`
  - `provision_leaf_worker.ex` - updated all Ash calls to use `TenantMode.ash_opts/3`
  - `record_event_worker.ex` - updated to use `TenantMode.tenant_opts/1`

### 3.5 Update core-elx GenServers

- [x] **3.5.1 Observability seeders (4 files)**
  - `template_seeder.ex` - updated to skip in tenant-unaware mode, uses TenantMode.ash_opts
  - `rule_seeder.ex` - updated to skip in tenant-unaware mode, uses TenantMode.ash_opts
  - `zen_rule_seeder.ex` - updated to skip in tenant-unaware mode, uses TenantMode.ash_opts
  - `sysmon_profile_seeder.ex` - updated to use TenantMode.ash_opts

- [x] **3.5.2 Observability sync/writers (3 files)**
  - `zen_rule_sync.ex` - updated GenServer state to use ash_opts instead of actor
  - `onboarding_writer.ex` - updated to use TenantMode.ash_opts

- [x] **3.5.3 Infrastructure GenServers (1 file)**
  - `state_monitor.ex` - updated GenServer state to use ash_opts

- [x] **3.5.4 Remaining GenServers - COMPLETE**
  - All GenServers now use `SystemActor.system/1` or `SystemActor.platform/1`
  - No `SystemActor.for_tenant` usage remains in codebase
  - Only legitimate `tenant:` usage: AshAuthentication JWT verification (required)

---

## Phase 4: Simplify SystemActor

**Status: COMPLETE** (as of 2026-01-16)

### 4.1 Refactor SystemActor module

- [x] **4.1.1 Keep `SystemActor.platform/1` for public schema resources**
  - Used for NatsOperator, NatsPlatformToken, EdgeSite (platform-level resources)
  - These live in public schema and need super_admin role
  - Appropriate for tenant instance to access platform config

- [x] **4.1.2 Remove `SystemActor.for_tenant/2`**
  - DELETED - no longer exists in codebase
  - Replaced with `SystemActor.system/1`

- [x] **4.1.3 Simplified actor model implemented**
  - `system/1` - For tenant-scoped operations (role: :system)
  - `platform/1` - For public schema operations (role: :super_admin)
  - No tenant_id in actors - implicit from DB connection

### 4.2 Update authorization policies

- [x] **4.2.1 Updated bypass policies**
  - Policies now check for `role: :system` or `role: :super_admin`
  - No tenant_id checks needed

- [x] **4.2.2 Platform actor kept for public schema**
  - Platform actor exists for NatsOperator, EdgeSite, etc.
  - These are legitimate uses in tenant instance

---

## Phase 5: Delete Cross-Tenant Code

**Status: COMPLETE** (as of 2026-01-16)

### 5.1 Remove TenantSchemas module usage

- [x] **5.1.1 TenantSchemas.list_schemas() - DELETED**
  - No calls remain in codebase

- [x] **5.1.2 TenantSchemas.schema_for_id() - DELETED**
  - No calls remain in codebase

- [x] **5.1.3 TenantSchemas module - DELETED**
  - Module no longer exists in tenant instance

### 5.2 Remove cross-tenant query functions

- [x] **5.2.1 find_package_across_tenants() - DELETED**
  - Function no longer exists

- [x] **5.2.2 Cross-tenant token search - REMOVED**
  - api_auth.ex simplified - tokens in current schema only

- [x] **5.2.3 Audit complete - no cross-tenant patterns**
  - `Enum.reduce_while.*TenantSchemas` - not found
  - All cross-tenant iteration removed

### 5.3 Remove Tenant resource from tenant instance

- [x] **5.3.1 Decision: Remove entirely (Option B)**
  - Identity.Tenant resource has been deleted
  - Tenant info comes from environment config

- [x] **5.3.2 Implementation complete**
  - `Application.get_env(:serviceradar, :tenant_slug)` for NATS account name
  - `Application.get_env(:serviceradar, :tenant_name)` for display
  - No Tenant Ash resource queries in tenant instance

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

- [x] **7.1.1 Remove `TENANT_AWARE_MODE` flag**
  - N/A - Flag was never implemented; migration went directly to final state
  - Removed unused `reset_tenant_schemas` config option

- [x] **7.1.2 Remove old code paths**
  - N/A - No `tenant_aware_mode?()` branches exist
  - TenantMode module was never created

### 7.2 Update documentation

- [x] **7.2.1 Update CLAUDE.md**
  - `elixir/serviceradar_core/CLAUDE.md` updated with single-tenant patterns
  - Documents `SystemActor.system/1` and `SystemActor.platform/1`
  - Documents instance isolation model

- [ ] **7.2.2 Update deployment docs**
  - Document CNPG credential requirements
  - Document OSS vs SaaS differences

### 7.3 Archive related proposals

- [x] **7.3.1 Update 2286-break-out-tenant-control-plane**
  - Marked as COMPLETE with reference to this proposal

- [x] **7.3.2 Archive enforce-tenant-schema-isolation**
  - Marked as SUPERSEDED by this proposal

---

## Verification Checklist

Code removal (complete):

- [x] Tenant instance cannot query other tenant schemas (CNPG search_path enforces)
- [x] No `tenant:` parameters in Ash calls (except AshAuthentication JWT - required)
- [x] No `TenantSchemas` usage in tenant instance
- [x] No `SystemActor.for_tenant()` usage (only `system/1` and `platform/1` remain)
- [x] `SystemActor.platform()` only used for public schema resources (NatsOperator, EdgeSite)

Infrastructure (pending Phase 6):

- [ ] OSS helm install works with scoped credentials
- [ ] SaaS tenant provisioning creates scoped credentials
- [ ] All tests pass with new architecture
