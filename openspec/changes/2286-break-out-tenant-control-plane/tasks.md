# Tasks: Break out Tenant/SaaS Control Plane

## Summary

**Goal**: Make the Tenant Instance (serviceradar/) a clean, self-contained deployment that works identically whether it's:
- A standalone OSS install
- One of many instances managed by the SaaS Control Plane

**The cleanup work** (Phases 2-4) removes "God Mode" code that doesn't belong in a tenant instance:
- `authorize?: false` bypasses
- Cross-tenant queries
- Tenant provisioning logic

**The Control Plane work** (Phase 3, 5) moves provisioning/scaling to `serviceradar-web/`:
- CNPG user/schema creation
- NATS account creation
- tenant-workload-operator
- Signup/billing UI

The tenant instance code doesn't change based on deployment mode - it's always the same.

---

## Phase 1: Deep Dive Analysis (Complete)

- [x] **1.1 Initial scan of `system_actor` usage**
  - Found in: TenantResolver, Inventory, Edge.Onboarding*, Infrastructure, Scope
  - web-ng has own hardcoded system_actor definitions (not using core's SystemActor)

- [x] **1.2 Inventory multi-tenant Ash resources**
  - Schema-based (`strategy: :context`): User, Token, Device, Gateway, Agent, etc. (most resources)
  - Attribute-based (`strategy: :attribute, global?: true`): TenantMembership
  - Global (no strategy): Tenant, NatsOperator, NatsPlatformToken

- [x] **1.3 Identify "God Mode" code paths**
  - GenServers: TenantRegistryLoader, PlatformTenantBootstrap, OperatorBootstrap
  - Workers: CreateAccountWorker, ProvisionLeafWorker, ProvisionCollectorWorker
  - Seeders: template_seeder, rule_seeder, zen_rule_seeder, sysmon_profile_seeder

- [x] **1.4 Map authorize?: false usage in production code**
  - web-ng/lib/serviceradar_web_ng/inventory.ex:120 - hardcoded system_actor
  - web-ng/lib/serviceradar_web_ng/infrastructure.ex:135 - hardcoded system_actor
  - web-ng/lib/serviceradar_web_ng_web/tenant_resolver.ex:9 - @system_actor module attr
  - web-ng/lib/serviceradar_web_ng/edge/onboarding_packages.ex:45,60,72 - authorize?: false
  - web-ng/lib/serviceradar_web_ng/edge/onboarding_events.ex:146 - authorize?: false
  - web-ng/lib/serviceradar_web_ng/accounts/scope.ex:42,52 - authorize?: false
  - 30+ occurrences in LiveView modules and API controllers

- [x] **1.5 Analyze identity architecture**
  - Tenant: public schema, global resource
  - TenantMembership: public schema, attribute-based with global?: true
  - User: tenant schema, context-based (per-tenant schema isolation)
  - Hybrid approach creates complexity - users exist in tenant schemas but memberships in public

## Phase 2: Code Cleanup (In web-ng and core-elx)

### 2.1 Remove authorize?: false from web-ng

- [ ] **2.1.1 ServiceRadarWebNG.Inventory**
  ```
  File: web-ng/lib/serviceradar_web_ng/inventory.ex:120
  Issue: defp build_query_opts(nil), do: [actor: system_actor(), authorize?: false]
  Fix: Require actor parameter, remove nil fallback
  ```

- [ ] **2.1.2 ServiceRadarWebNG.Infrastructure**
  ```
  File: web-ng/lib/serviceradar_web_ng/infrastructure.ex:135
  Issue: Same pattern as Inventory
  Fix: Require actor parameter, remove nil fallback
  ```

- [ ] **2.1.3 ServiceRadarWebNGWeb.TenantResolver**
  ```
  File: web-ng/lib/serviceradar_web_ng_web/tenant_resolver.ex:9-15
  Issue: Hardcoded @system_actor module attribute
  Fix: Use ServiceRadar.Actors.SystemActor.platform(:tenant_resolver)
  ```

- [ ] **2.1.4 ServiceRadarWebNG.Edge.OnboardingPackages**
  ```
  Files: Lines 45, 60, 72, 294
  Issue: opts = [actor: system_actor(), authorize?: false, tenant: tenant]
  Fix: Remove authorize?: false, ensure system_actor provides proper authorization
  ```

- [ ] **2.1.5 ServiceRadarWebNG.Edge.OnboardingEvents**
  ```
  File: Line 146
  Issue: Ash.get(Tenant, tenant_id, authorize?: false)
  Fix: Use SystemActor.platform for tenant lookup
  ```

- [ ] **2.1.6 ServiceRadarWebNG.Accounts.Scope**
  ```
  File: Lines 42, 52
  Issue: authorize?: false for tenant/membership loading
  Fix: Use SystemActor.platform for scope building
  ```

- [ ] **2.1.7 Audit and fix remaining LiveView modules**
  - settings/rules_live/index.ex:81
  - admin/nats_live/show.ex:441,454
  - admin/nats_live/index.ex:327,361,382
  - admin/integration_live/index.ex:1226,1249,1274,1301,1320
  - admin/edge_sites_live/show.ex:104,465,478,489,495,515
  - admin/edge_sites_live/index.ex:637,650,684,706,720
  - admin/edge_package_live/index.ex:995
  - admin/collector_live/index.ex:772,813,827,841,878,893,906
  - agent_live/show.ex:225

- [ ] **2.1.8 Audit and fix API controllers**
  - api/device_controller.ex:35,164,239
  - api/nats_controller.ex:38,144,228,235,246
  - api/enroll_controller.ex:187,242
  - api/edge_controller.ex:219,482,509
  - api/collector_controller.ex:53,88,117,192,200,245,324,413,564,598

- [ ] **2.1.9 Audit auth plugs**
  - plugs/tenant_context.ex:129
  - plugs/api_auth.ex:89,173,216,273
  - user_auth.ex:63
  - controllers/tenant_controller.ex:36

### 2.2 Consolidate system_actor definitions

- [ ] **2.2.1 Remove duplicate system_actor in web-ng**
  - Delete: web-ng/lib/serviceradar_web_ng/inventory.ex:124-129 (system_actor/0)
  - Delete: web-ng/lib/serviceradar_web_ng/infrastructure.ex:139-145 (system_actor/0)
  - Delete: web-ng/lib/serviceradar_web_ng_web/tenant_resolver.ex:9-15 (@system_actor)
  - Delete: web-ng/lib/serviceradar_web_ng/edge/onboarding_packages.ex:274-280 (system_actor/0)
  - Delete: web-ng/lib/serviceradar_web_ng/edge/onboarding_events.ex:126-132 (system_actor/0)
  - Delete: web-ng/lib/serviceradar_web_ng/edge/workers/expire_packages_worker.ex:76-82 (system_actor/0)
  - Replace with: alias ServiceRadar.Actors.SystemActor

### 2.3 Make tenant context required

- [ ] **2.3.1 Update Infrastructure module**
  - Remove nil fallback in build_query_opts
  - Make actor required parameter
  - Update all callers

- [ ] **2.3.2 Update Inventory module**
  - Same as Infrastructure

- [ ] **2.3.3 Remove "backward compatibility" comments**
  - These patterns are security holes, not backward compat

## Phase 3: Control Plane Separation (serviceradar-web/)

### 3.1 Set up serviceradar-web as Control Plane

- [ ] **3.1.1 Add Ash/Identity dependencies to serviceradar-web**
  - Add ash, ash_postgres, ash_authentication deps to mix.exs
  - Configure database connection (separate Control Plane DB or shared with access to public schema)
  - Set up Repo module

- [ ] **3.1.2 Move tenant-workload-operator to serviceradar-web**
  - Copy Go code from `serviceradar/cmd/tenant-workload-operator/`
  - Update Helm chart references to point to serviceradar-web images
  - Remove from OSS repo (or make optional in Helm values)

- [ ] **3.1.3 Create signup/tenant creation UI**
  - Tenant signup LiveView
  - Plan selection
  - Initial user creation
  - Email verification flow

### 3.2 Extract Control Plane components to serviceradar-web

- [ ] **3.2.1 Move identity management**
  - Copy Tenant resource (or create simplified version)
  - Create global User registry (email -> tenant mappings)
  - TenantMembership management UI
  - Platform tenant bootstrap logic

- [ ] **3.2.2 Move NATS provisioning**
  - Copy NatsOperator resource
  - Copy CreateAccountWorker (Oban job)
  - Copy ProvisionLeafWorker
  - Copy ServiceAccountBootstrap

- [ ] **3.2.3 Move tenant lifecycle**
  - Copy TenantRegistryLoader (or implement differently)
  - Copy TenantLifecyclePublisher
  - Tenant event stream management

### 3.3 Implement Control Plane API

- [ ] **3.3.1 Design API endpoints**
  - POST /api/tenants - Create tenant (triggers provisioning)
  - GET /api/tenants - List tenants (admin only)
  - GET /api/tenants/:id - Get tenant
  - PUT /api/tenants/:id - Update tenant
  - DELETE /api/tenants/:id - Soft delete tenant
  - POST /api/tenants/:id/users - Add user to tenant
  - POST /api/tenants/:id/jwt - Generate tenant JWT

- [ ] **3.3.2 Implement JWT generation**
  - JWT claim structure
  - Signing key management (rotate via K8s secrets)
  - Token expiry/refresh mechanism
  - Publish public key for Tenant Instances to validate

## Phase 4: JWT-Based Authorization

### 4.1 Tenant Instance JWT validation

- [ ] **4.1.1 Add JWT middleware**
  - Validate JWT signature
  - Extract tenant_id, user_id, role from claims
  - Build actor from JWT claims

- [ ] **4.1.2 Remove TenantMembership queries**
  - Scope.for_user no longer queries TenantMembership
  - Authorization derived from JWT claims

### 4.2 Architecture decision: JWT claim structure

- [ ] **4.2.1 Define JWT standard**
  ```json
  {
    "sub": "user-uuid",
    "tenant_id": "tenant-uuid",
    "role": "admin|operator|viewer|system",
    "component": "optional-system-component-name",
    "iss": "serviceradar-control-plane",
    "aud": "serviceradar-tenant-instance",
    "exp": 1234567890,
    "iat": 1234567890
  }
  ```

## Phase 5: Helm & Bootstrap

### 5.1 OSS Deployment (Single-Tenant) - serviceradar/ repo

- [ ] **5.1.1 Create platform-bootstrap-job**
  - Helm Job that runs on install/upgrade
  - Auto-create platform tenant in CNPG
  - Generate initial admin user
  - Configure NATS credentials for single tenant

- [ ] **5.1.2 Update values.yaml defaults**
  - Single tenant mode by default
  - Remove tenant-workload-operator from OSS chart
  - Simplify configuration (no tenant selection)
  - Remove multi-tenant GenServers (TenantRegistryLoader, etc.)

- [ ] **5.1.3 Remove SaaS-specific components from OSS**
  - tenant-workload-operator CRDs
  - TenantWorkloadSet/TenantWorkloadTemplate resources
  - Multi-tenant NATS account provisioning

### 5.2 SaaS Deployment (Multi-Tenant) - serviceradar-web/ repo

- [ ] **5.2.1 Create SaaS Helm chart in serviceradar-web/**
  - Control Plane deployment (serviceradar-web app)
  - Shared NATS/CNPG configuration
  - tenant-workload-operator deployment
  - Per-tenant deployment templates

- [ ] **5.2.2 Tenant provisioning flow**
  - User signs up via Control Plane UI
  - Control Plane creates tenant record
  - NATS account provisioned via CreateAccountWorker
  - CNPG schema created via migration
  - tenant-workload-operator deploys Tenant Instance pods
  - JWT issued to user for Tenant Instance access

## Phase 6: Verification - Clean Single-Tenant Deployment

### 6.1 OSS Deployment Smoke Test

- [ ] **6.1.1 Helm install verification**
  ```bash
  # This MUST work with zero external dependencies
  helm install serviceradar ./helm/serviceradar -n serviceradar --create-namespace
  # System should be fully functional after ~2 minutes
  ```

- [ ] **6.1.2 Docker Compose verification**
  ```bash
  # This MUST work with zero external dependencies
  docker compose up -d
  # System should be fully functional
  ```

- [ ] **6.1.3 Verify NO Control Plane code paths executed**
  - TenantRegistryLoader should NOT start (or be removed)
  - No cross-tenant queries in logs
  - No "platform tenant" special cases needed
  - No tenant-workload-operator CRDs required

### 6.2 Code Removal Checklist

- [ ] **6.2.1 Remove or disable multi-tenant GenServers in OSS**
  - TenantRegistryLoader - remove or make optional
  - PlatformTenantBootstrap - simplify to just create default tenant
  - Tenant selection UI - remove from web-ng

- [ ] **6.2.2 Remove tenant-workload-operator from OSS Helm**
  - Delete templates/tenant-workload-operator.yaml
  - Delete templates/tenant-workload-templates.yaml
  - Delete crds/tenantworkloadsets.yaml
  - Delete crds/tenantworkloadtemplates.yaml

- [ ] **6.2.3 Simplify web-ng for single-tenant**
  - Remove tenant switcher from navbar
  - Remove /admin routes that manage tenants
  - Default to platform tenant context always

## Phase 7: Documentation

- [ ] **7.1 Update CLAUDE.md**
  - Remove multi-tenant patterns from OSS docs
  - Document single-tenant deployment
  - Document that SaaS features are in separate repo

- [ ] **7.2 Create migration guide**
  - Existing deployment upgrade path
  - Breaking changes documentation

- [ ] **7.3 Update tests**
  - Remove authorize?: false from test helpers (where possible)
  - Add single-tenant deployment integration test
