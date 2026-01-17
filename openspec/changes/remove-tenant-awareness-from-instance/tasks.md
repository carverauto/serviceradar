# Tasks: Remove Tenant Awareness from Tenant Instance

## Summary

Make instance code (web-ng, core-elx) completely schema-scoped and tenant-unaware by:
1. Using schema-scoped CNPG credentials (DB enforces isolation)
2. Using account-scoped NATS JWTs (NATS enforces isolation)
3. Removing all `tenant:` parameters from Ash queries
4. Removing cross-schema code paths entirely

---

## Phase 1: Control Plane - CNPG User Provisioning

### 1.1 Create CNPG user provisioning in Control Plane

- [x] **1.1.1 Add CNPG user creation to account provisioning flow**
  - Created `CNPG.Provisioner` module for PostgreSQL user/schema management
  - Created `CreateCnpgUserWorker` Oban worker for async provisioning
  - Creates PostgreSQL user: `account_{slug}_app`
  - Grants: USAGE on account schema, ALL on tables/sequences
  - Sets: `search_path` to account schema
  - Stores: credentials in K8s secret via `K8s.SecretManager`

- [x] **1.1.2 Create migration to add CNPG fields to Tenant resource**
  - Added `cnpg_username` and `cnpg_password_secret_ref` to Tenant resource
  - Created migration `20260115100000_add_cnpg_user_fields.exs`
  - Updated `set_cnpg_ready` action to accept new fields

- [x] **1.1.3 Wire up account provisioning to create CNPG user**
  - Updated `TenantController.create/2` to enqueue `CreateCnpgUserWorker`
  - CNPG provisioning runs in parallel with NATS provisioning
  - Added `cnpg_provisioning` queue to Oban config

- [x] **1.1.4 Move workload provisioning to control plane repo**
  - Tenant workload operator and templates live in `~/serviceradar-web`
  - This repo no longer builds or publishes that image

### 1.2 Test CNPG isolation

- [ ] **1.2.1 Create test account with scoped credentials**
- [ ] **1.2.2 Verify cannot access other account schemas**
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

### 2.2 Remove multitenancy DSL and regenerate snapshots

- [x] **2.2.1 Remove multitenancy blocks from Ash resources**
  - COMPLETE - No multitenancy blocks remain in Ash resources
  - No `strategy :context` or `attribute :tenant_id` in codebase

- [x] **2.2.2 Regenerate Ash snapshots and migrations**
  - Ran `mix ash.codegen`; no changes detected

---

## Phase 3: Remove tenant: Parameter from Code

**Status: COMPLETE** (as of 2026-01-16)

**Migration Guide**: See `migration-guide.md` for patterns and examples.

### 3.1 Update web-ng controllers

- [x] **3.1.1 api/collector_controller.ex** (EXAMPLE FILE)
  - Updated all Ash calls to omit `tenant:` params
  - Removed cross-schema lookup helper
  - Platform operations use standard system actors

- [x] **3.1.2 api/edge_controller.ex**
  - Updated all Ash calls to omit `tenant:` params
  - Removed cross-schema lookup helper

- [x] **3.1.3 api/enroll_controller.ex**
  - Updated `mark_enrolled()` to omit `tenant:` params
  - Removed cross-schema lookup helper

- [x] **3.1.4 api/nats_controller.ex** (Control Plane only)
  - No changes needed - manages NatsOperator/NatsPlatformToken in public schema

- [x] **3.1.5 auth_controller.ex**
  - Updated JWT token generation to omit `tenant:` params

- [x] **3.1.6 tenant_controller.ex** (Control Plane only)
  - No changes needed - control plane feature

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
  - Updated `find_api_token()` with schema scope check (single-schema only)
  - Updated `record_token_usage()` to use `Ash` calls without `tenant:` params
  - Updated `validate_ash_jwt()` to use mode-conditional actors
  - Removed redundant private `tenant_opts/1` helper

- [x] **3.3.2 plugs/tenant_context.ex**
  - Updated `load_tenant()` to use `SystemActor.system/1`
  - Tenant resource is in public schema, no tenant: parameter needed

- [x] **3.3.3 accounts/scope.ex**
  - Updated `for_user()` to use `SystemActor.system/1`
  - Updated `fetch_tenant_by_id()` to use mode-conditional actor
  - Removed `tenant: nil` (no longer needed with mode-conditional actors)

- [x] **3.3.4 user_auth.ex**
  - Updated `verify_token()` to use `Ash` calls without `tenant:` params
  - Updated actor to use `SystemActor.system/1`
  - Removed redundant private `tenant_opts/1` helper

### 3.4 Update core-elx workers

- [x] **3.4.1 Audit all Oban workers for `tenant:` usage**
  - Found 3 edge workers: `provision_collector_worker.ex`, `provision_leaf_worker.ex`, `record_event_worker.ex`
  - Found 44 files total with `SystemActor.for_tenant` usage

- [x] **3.4.2 Update edge workers (3 files)**
  - `provision_collector_worker.ex` - updated all Ash calls to use `Ash` calls without `tenant:` params
  - `provision_leaf_worker.ex` - updated all Ash calls to use `Ash` calls without `tenant:` params
  - `record_event_worker.ex` - updated to use `Ash` calls without `tenant:` params

### 3.5 Update core-elx GenServers

- [x] **3.5.1 Observability seeders (4 files)**
  - `template_seeder.ex` - updated to skip in tenant-unaware mode, uses Ash calls without tenant params
  - `rule_seeder.ex` - updated to skip in tenant-unaware mode, uses Ash calls without tenant params
  - `zen_rule_seeder.ex` - updated to skip in tenant-unaware mode, uses Ash calls without tenant params
  - `sysmon_profile_seeder.ex` - updated to use Ash calls without tenant params

- [x] **3.5.2 Observability sync/writers (3 files)**
  - `zen_rule_sync.ex` - updated GenServer state to use ash_opts instead of actor
  - `onboarding_writer.ex` - updated to use Ash calls without tenant params

- [x] **3.5.3 Infrastructure GenServers (1 file)**
  - `state_monitor.ex` - updated GenServer state to use ash_opts

- [x] **3.5.4 Remaining GenServers - COMPLETE**
  - All GenServers now use `SystemActor.system/1`
  - No `SystemActor.for_tenant` usage remains in codebase
  - Only legitimate `tenant:` usage: AshAuthentication JWT verification (required)

---

## Phase 4: Simplify SystemActor

**Status: COMPLETE** (as of 2026-01-16)

### 4.1 Refactor SystemActor module

- [x] **4.1.1 Remove `SystemActor.platform/1`**
  - No public-schema access in tenant instances
  - Control Plane owns platform resources

- [x] **4.1.2 Remove `SystemActor.for_tenant/2`**
  - DELETED - no longer exists in codebase
  - Replaced with `SystemActor.system/1`

- [x] **4.1.3 Simplified actor model implemented**
  - `system/1` - For instance-scoped operations (role: :system)
  - No tenant_id in actors - implicit from DB connection

### 4.2 Update authorization policies

- [x] **4.2.1 Updated bypass policies**
  - Policies now check for `role: :system` only
  - No tenant_id checks needed

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
  - Instance metadata comes from environment/config

- [x] **5.3.2 Implementation complete**
  - `Application.get_env(:serviceradar, :nats_account_name)` for NATS account
  - No Tenant Ash resource queries in tenant instance

---

## Phase 6: Single-Deployment Mode

### 6.1 Update Helm bootstrap for OSS

- [x] **6.1.1 Create default schema in bootstrap job (if needed)**
  - Added `cnpg.schema` option to values.yaml (default: `platform`)
  - Updated spire-postgres.yaml postInitApplicationSQL to:
    - Create schema with `CREATE SCHEMA IF NOT EXISTS {schema} AUTHORIZATION serviceradar`
    - Grant permissions with `GRANT ALL ON SCHEMA {schema} TO serviceradar`
    - Set user search_path with `ALTER ROLE serviceradar SET search_path TO {schema},ag_catalog`

- [x] **6.1.2 Configure pods with scoped credentials**
  - Updated db-event-writer-config.yaml to derive search_path from cnpg.schema
  - Updated serviceradar-config.yaml to derive search_path from cnpg.schema
  - All pods use the same pattern: schema comes from values, search_path is auto-derived

### 6.2 Test OSS deployment

- [ ] **6.2.1 `helm install` smoke test**
  - Verify system works with scoped credentials

- [ ] **6.2.2 Verify no cross-schema code paths**
  - Check logs for any cross-schema access attempts

### 6.3 Infrastructure cleanup (certs/Helm/Compose)

- [x] **6.3.1 Remove account-scoped cert generation**
  - Edge component certs now live under `/etc/serviceradar/certs/components`
  - CN format: `<component_id>.<partition_id>.serviceradar`
  - SPIFFE format: `spiffe://serviceradar.local/<component_type>/<partition_id>/<component_id>`

- [x] **6.3.2 Update Helm/Compose config to drop tenant fields**
  - Removed tenant CA secret and tenant values from Helm
  - Removed tenant slug/id env vars from agent-gateway and Compose
  - Updated agent gateway security config to use root CA chain

- [x] **6.3.3 Remove tenant-workload-operator artifacts from this repo**
  - Dropped Bazel image targets and push entries

- [x] **6.3.4 Remove external tenant fields from sync types**
  - Dropped NetBox `tenant` field from sync types

---

## Phase 7: Cleanup and Documentation

### 7.1 Remove feature flag

- [x] **7.1.1 Remove `TENANT_AWARE_MODE` flag**
  - N/A - Flag was never implemented; migration went directly to final state
  - Removed unused `reset_tenant_schemas` config option

- [x] **7.1.2 Remove old code paths**
  - N/A - No `tenant_aware_mode?()` branches exist
  
### 7.2 Update documentation

- [x] **7.2.1 Update CLAUDE.md**
  - `elixir/serviceradar_core/CLAUDE.md` updated with single-tenant patterns
  - Documents `SystemActor.system/1`
  - Documents instance isolation model

- [x] **7.2.2 Update deployment docs**
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

- [x] Deployment instance cannot query other schemas (CNPG search_path enforces)
- [x] No `tenant:` parameters in Ash calls (except AshAuthentication JWT - required)
- [x] No `TenantSchemas` usage in tenant instance
- [x] No `SystemActor.for_tenant()` usage (only `system/1` remains)
- [x] No `SystemActor.platform()` usage remains in tenant instance code

Infrastructure (pending Phase 6):

- [ ] OSS helm install works with scoped credentials
- [ ] SaaS control plane provisioning creates scoped credentials
- [ ] All tests pass with new architecture
