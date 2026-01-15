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

## Phase 2: Code Cleanup (In web-ng and core-elx) ✅ COMPLETE

### 2.1 Remove authorize?: false from web-ng ✅

- [x] **2.1.1 ServiceRadarWebNG.Inventory** - DELETED (dead code, no callers)

- [x] **2.1.2 ServiceRadarWebNG.Infrastructure** - DELETED (dead code, no callers)

- [x] **2.1.3 ServiceRadarWebNGWeb.TenantResolver**
  - Fixed: Now uses `SystemActor.platform(:tenant_resolver)`

- [x] **2.1.4 ServiceRadarWebNG.Edge.OnboardingPackages**
  - Fixed: Converted to tenant-aware `SystemActor.for_tenant()`
  - Removed all `authorize?: false` (8 instances)

- [x] **2.1.5 ServiceRadarWebNG.Edge.OnboardingEvents**
  - Fixed: Uses `SystemActor.for_tenant()` and `SystemActor.platform()`

- [x] **2.1.6 ServiceRadarWebNG.Accounts.Scope**
  - Fixed: Uses `SystemActor.platform(:scope)`

- [x] **2.1.7 Audit and fix remaining LiveView modules**
  - All fixed with appropriate SystemActor usage:
    - settings/rules_live/index.ex
    - admin/nats_live/show.ex, index.ex
    - admin/integration_live/index.ex
    - admin/edge_sites_live/show.ex, index.ex
    - admin/edge_package_live/index.ex
    - admin/collector_live/index.ex
    - agent_live/show.ex
    - auth_live/register.ex

- [x] **2.1.8 Audit and fix API controllers**
  - All fixed:
    - api/device_controller.ex - `SystemActor.platform(:device_controller)`
    - api/nats_controller.ex - `SystemActor.platform(:nats_controller)`
    - api/enroll_controller.ex - `SystemActor.platform(:enroll_controller)`
    - api/edge_controller.ex - `SystemActor.platform(:edge_controller)`
    - api/collector_controller.ex - Mixed tenant/platform actors

- [x] **2.1.9 Audit auth plugs**
  - All fixed:
    - plugs/tenant_context.ex - `SystemActor.platform(:tenant_context)`
    - plugs/api_auth.ex - `SystemActor.platform(:api_auth)`
    - user_auth.ex - `SystemActor.platform(:user_auth)`
    - controllers/tenant_controller.ex - `SystemActor.platform()`

### 2.2 Consolidate system_actor definitions ✅

- [x] **2.2.1 Remove duplicate system_actor in web-ng**
  - Deleted: inventory.ex, infrastructure.ex (entire files - dead code)
  - Fixed: tenant_resolver.ex, onboarding_packages.ex, onboarding_events.ex, expire_packages_worker.ex
  - All now use: `alias ServiceRadar.Actors.SystemActor`

### 2.3 Make tenant context required ✅

- [x] **2.3.1 Update Infrastructure module** - N/A (deleted)
- [x] **2.3.2 Update Inventory module** - N/A (deleted)
- [x] **2.3.3 Remove "backward compatibility" comments** - Done via deletion

## Phase 3: Control Plane Separation (serviceradar-web/) - IN PROGRESS

### 3.1 Set up serviceradar-web as Control Plane

- [x] **3.1.1 Add Ash/Identity dependencies to serviceradar-web**
  - Added ash ~> 3.11, ash_postgres ~> 2.6, ash_phoenix ~> 2.0
  - Added ash_authentication ~> 4.13, ash_authentication_phoenix ~> 2.0
  - Added ecto_sql ~> 3.13, postgrex, oban ~> 2.20, simple_sat ~> 0.1
  - Created ServiceRadarWeb.Repo (AshPostgres.Repo)
  - Configured dev/test database settings
  - Added Oban with queues: default, nats_provisioning, tenant_lifecycle

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

- [x] **3.2.1 Create Control Plane domain and resources**
  - Created ServiceRadarWeb.ControlPlane domain
  - Created ServiceRadarWeb.ControlPlane.Tenant resource with:
    - Basic tenant info (name, slug, status, plan)
    - CNPG provisioning fields (cnpg_status, database_name, schema_name)
    - NATS provisioning fields (nats_status, account_public_key, account_jwt)
    - Actions: create, update, suspend, activate, set_cnpg_ready, set_nats_ready
  - Created ServiceRadarWeb.ControlPlane.NatsOperator resource with:
    - Operator management (bootstrap, set_ready, set_error)
    - Single operator per platform (unique name)

- [x] **3.2.2 Move NATS provisioning workers**
  - Created `ServiceRadarWeb.ControlPlane.Workers.CreateAccountWorker` (Oban job)
  - Created `ServiceRadarWeb.ControlPlane.NATS.AccountClient` (gRPC client to datasvc)
  - Copied proto definitions to `lib/serviceradar_web/proto/nats_account.pb.ex`
  - Added grpc ~> 0.9, protobuf ~> 0.13 dependencies
  - Worker stores account_public_key and account_jwt in DB
  - Account seed to be stored in K8s secrets (TODO placeholder)
  - Generated database migrations for Control Plane resources

- [ ] **3.2.3 Move tenant lifecycle**
  - Implement tenant lifecycle events via PubSub
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
