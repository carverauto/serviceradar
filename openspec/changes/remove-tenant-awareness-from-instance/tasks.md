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

- [ ] **1.1.1 Add CNPG user creation to tenant provisioning flow**
  - Control Plane creates PostgreSQL user: `tenant_{slug}_app`
  - Grant: USAGE on tenant schema, ALL on tables/sequences
  - Set: `search_path` to tenant schema
  - Store: credentials in K8s secret

- [ ] **1.1.2 Create migration to add CNPG fields to Tenant resource**
  ```elixir
  attribute :cnpg_username, :string
  attribute :cnpg_password_secret_ref, :string  # K8s secret reference
  attribute :cnpg_schema, :string
  ```

- [ ] **1.1.3 Update CreateAccountWorker to also create CNPG user**
  - After NATS account creation, create CNPG user
  - Store secret in K8s: `serviceradar-tenant-{slug}-cnpg-creds`

- [ ] **1.1.4 Update tenant-workload-operator to inject CNPG credentials**
  - Read CNPG secret for tenant
  - Set `CNPG_*` environment variables on tenant pods
  - Set `search_path` in connection URL

### 1.2 Test CNPG isolation

- [ ] **1.2.1 Create test tenant with scoped credentials**
- [ ] **1.2.2 Verify cannot access other tenant schemas**
- [ ] **1.2.3 Verify app works with scoped credentials**

---

## Phase 2: Remove Multitenancy from Ash Resources

### 2.1 Audit current multitenancy configuration

- [ ] **2.1.1 List all resources with `multitenancy` blocks**
  - Expected: Most resources in Identity, Edge, Inventory domains

- [ ] **2.1.2 List all resources with `tenant_id` attributes**
  - Determine which are actually needed vs redundant

- [ ] **2.1.3 Identify resources that should stay in public schema**
  - These need special handling (move to Control Plane or replicate)

### 2.2 Create feature flag for gradual migration

- [ ] **2.2.1 Add `TENANT_AWARE_MODE` environment variable**
  - Default: `true` (current behavior)
  - When `false`: skip tenant context

- [ ] **2.2.2 Update Repo configuration**
  ```elixir
  # When TENANT_AWARE_MODE=false, don't set dynamic schema
  def tenant_schema do
    if tenant_aware_mode?() do
      # Current behavior
    else
      nil  # Use connection's search_path
    end
  end
  ```

### 2.3 Remove multitenancy from resources (behind flag)

- [ ] **2.3.1 Update ServiceRadar.Inventory domain resources**
  - Device, Agent, Gateway, Interface, etc.
  - Remove `multitenancy` block
  - Remove `tenant_id` attribute (if redundant)

- [ ] **2.3.2 Update ServiceRadar.Edge domain resources**
  - EdgeSite, CollectorPackage, OnboardingPackage, etc.

- [ ] **2.3.3 Update ServiceRadar.Identity domain resources**
  - User, ApiToken, etc.
  - Note: Tenant, TenantMembership move to Control Plane

- [ ] **2.3.4 Update ServiceRadar.Monitoring domain resources**
  - Alert rules, alert states, etc.

- [ ] **2.3.5 Generate migrations to drop tenant_id columns**
  - Only for columns that are purely redundant

---

## Phase 3: Remove tenant: Parameter from Code

### 3.1 Update web-ng controllers

- [ ] **3.1.1 api/collector_controller.ex**
  - Remove `tenant:` from all Ash calls
  - Remove `find_package_across_tenants()` entirely
  - Simplify `require_tenant()` - tenant is implicit

- [ ] **3.1.2 api/device_controller.ex**
  - Remove `tenant:` parameters
  - Simplify actor creation

- [ ] **3.1.3 api/edge_controller.ex**
  - Remove `tenant:` parameters

- [ ] **3.1.4 api/nats_controller.ex**
  - Remove `tenant:` parameters

- [ ] **3.1.5 api/enroll_controller.ex**
  - Remove `tenant:` parameters

- [ ] **3.1.6 All other API controllers**
  - Audit and update

### 3.2 Update web-ng LiveViews

- [ ] **3.2.1 Audit all LiveViews for `tenant:` usage**
  - Use grep: `tenant:` in `web-ng/lib/serviceradar_web_ng_web/live/`

- [ ] **3.2.2 Update each LiveView**
  - Remove `tenant:` from `Ash.read!`, `Ash.create!`, etc.
  - Simplify scope/actor handling

### 3.3 Update web-ng plugs and auth

- [ ] **3.3.1 plugs/api_auth.ex**
  - Remove `TenantSchemas` usage
  - Simplify - no tenant context needed

- [ ] **3.3.2 plugs/tenant_context.ex**
  - Simplify or remove - tenant is implicit

- [ ] **3.3.3 accounts/scope.ex**
  - Remove tenant_id tracking
  - Simplify `Scope` struct

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
