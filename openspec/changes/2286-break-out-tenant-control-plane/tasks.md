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
  - elixir/web-ng/lib/serviceradar_web_ng/inventory.ex:120 - hardcoded system_actor
  - elixir/web-ng/lib/serviceradar_web_ng/infrastructure.ex:135 - hardcoded system_actor
  - elixir/web-ng/lib/serviceradar_web_ng_web/tenant_resolver.ex:9 - @system_actor module attr
  - elixir/web-ng/lib/serviceradar_web_ng/edge/onboarding_packages.ex:45,60,72 - authorize?: false
  - elixir/web-ng/lib/serviceradar_web_ng/edge/onboarding_events.ex:146 - authorize?: false
  - elixir/web-ng/lib/serviceradar_web_ng/accounts/scope.ex:42,52 - authorize?: false
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

- [x] **3.1.2 Move tenant-workload-operator to serviceradar-web**
  - Copied Go code to `serviceradar-web/cmd/tenant-workload-operator/`
  - Created standalone go.mod with required dependencies (nats.go, k8s.io/api, controller-runtime)
  - Created Dockerfile for containerization
  - Created Helm chart at `helm/control-plane/`:
    - CRDs: TenantWorkloadSet, TenantWorkloadTemplate
    - Templates: tenant-workload-operator deployment, workload templates
    - Values.yaml with full configuration options
  - Created Makefile for building and packaging
  - Updated image references to ghcr.io/carverauto/serviceradar-tenant-workload-operator

- [x] **3.1.3 Create signup/tenant creation UI**
  - Created `ServiceRadarWebWeb.SignupLive` - Multi-step signup wizard:
    - Step 1: Organization info (name, slug, contact email)
    - Step 2: Plan selection (Free, Pro, Enterprise)
    - Step 3: Confirmation and terms acceptance
    - Step 4: Success with provisioning status
  - Created `ServiceRadarWebWeb.Admin.TenantsLive` - Admin tenant management:
    - List all tenants with status filtering
    - Create new tenants
    - Suspend/activate tenants
    - Retry NATS provisioning
    - View provisioning status (CNPG, NATS)
  - Routes: /signup, /admin/tenants
  - TODO: Email verification flow (requires mailer setup)
  - TODO: Authentication for admin routes

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

- [x] **3.2.3 Move tenant lifecycle**
  - Created `ServiceRadarWeb.ControlPlane.Events.TenantLifecycle` module
  - Event types: created, activated, suspended, deleted, provisioning_started/completed/failed, cnpg_ready/error, nats_ready/error
  - PubSub subscription: `TenantLifecycle.subscribe()` and `TenantLifecycle.subscribe(tenant_id)`
  - Integrated into CreateAccountWorker for NATS provisioning events
  - Admin TenantsLive subscribes for real-time UI updates

### 3.3 Implement Control Plane API

- [x] **3.3.1 Design API endpoints**
  - Created `ServiceRadarWebWeb.API.TenantController`:
    - POST /api/tenants - Create tenant (triggers NATS provisioning)
    - GET /api/tenants - List tenants with status/plan filtering
    - GET /api/tenants/:id - Get tenant details
    - PUT /api/tenants/:id - Update tenant
    - DELETE /api/tenants/:id - Soft delete tenant
    - POST /api/tenants/:id/suspend - Suspend tenant
    - POST /api/tenants/:id/activate - Activate tenant
  - Created `ServiceRadarWebWeb.API.OperatorController`:
    - GET /api/operator - Get operator status
    - POST /api/operator/bootstrap - Bootstrap NATS operator
  - Created `ServiceRadarWebWeb.FallbackController` for error handling
  - TODO: POST /api/tenants/:id/users - Add user to tenant
  - TODO: POST /api/tenants/:id/jwt - Generate tenant JWT

- [x] **3.3.2 Implement JWT generation**
  - Created `ServiceRadarWeb.ControlPlane.Auth.JWT` module
  - JWT structure with: sub, tenant_id, tenant_slug, role, component, iss, aud, exp, iat, jti
  - Key management: JWT_SIGNING_KEY env var, JWT_SIGNING_KEY_FILE, or ephemeral (dev/test)
  - Added JOSE ~> 1.11 dependency
  - API endpoints:
    - POST /api/tenants/:id/jwt/user - Generate user JWT
    - POST /api/tenants/:id/jwt/system - Generate system JWT (for collectors/services)
  - Token types: user (1hr default), system (24hr default)

## Phase 4: JWT-Based Authorization ✅ COMPLETE

### 4.1 Tenant Instance JWT validation ✅

- [x] **4.1.1 Add JWT middleware**
  - Created `ServiceRadarWebNG.Auth.ControlPlaneJWT` module
    - Validates JWT signature using JOSE/RS256
    - Extracts tenant_id, user_id, role, component from claims
    - `build_actor/1` creates Ash-compatible actors from claims
    - Supports both user tokens and system tokens
  - Updated `ServiceRadarWebNGWeb.Plugs.ApiAuth` to:
    - Try AshAuthentication JWT first (user session tokens)
    - Fall back to Control Plane JWT validation
    - Build actor and set tenant context from Control Plane claims
  - Configuration via runtime.exs:
    - `CONTROL_PLANE_PUBLIC_KEY` - PEM-encoded public key
    - `CONTROL_PLANE_PUBLIC_KEY_FILE` - Path to public key file
    - `CONTROL_PLANE_JWT_ISSUER` - Expected issuer (default: "serviceradar-control-plane")
    - `CONTROL_PLANE_JWT_AUDIENCE` - Expected audience (default: "serviceradar-tenant-instance")

- [x] **4.1.2 JWT claims structure**
  - Standard claims implemented in ControlPlaneJWT:
    - `sub` - User ID (UUID) or system identifier
    - `tenant_id` - Tenant ID (UUID) this token is authorized for
    - `tenant_slug` - Human-readable tenant slug
    - `role` - One of: admin, operator, viewer, system
    - `component` - Optional system component name (for system tokens)
    - `iss` - Issuer: "serviceradar-control-plane"
    - `aud` - Audience: "serviceradar-tenant-instance"
    - `exp` - Expiration timestamp
    - `iat` - Issued at timestamp
    - `jti` - Unique token ID

- [x] **4.1.3 Actor building from JWT claims**
  - User tokens create actor: `%{id: user_id, tenant_id: tenant_id, role: role, email: nil}`
  - System tokens create actor: `%{id: "system:component", tenant_id: tenant_id, role: :system, component: component}`
  - Actors compatible with Ash authorization system

### 4.2 Architecture notes

- Control Plane JWT validation is **optional** - OSS deployments work without it
- When public key is not configured, `:public_key_not_configured` error is returned
- This allows the same codebase for both OSS and SaaS deployments
- TenantMembership queries still used for browser-based sessions
- JWT-based auth bypasses TenantMembership for API requests from Control Plane

## Phase 5: Helm & Bootstrap

### 5.1 OSS Deployment (Single-Tenant) - serviceradar/ repo

- [ ] **5.1.1 Create platform-bootstrap-job**
  - Helm Job that runs on install/upgrade
  - Auto-create platform tenant in CNPG
  - Generate initial admin user
  - Configure NATS credentials for single tenant

- [x] **5.1.2 Update values.yaml defaults**
  - Set `tenantWorkloadOperator.enabled: false` by default
  - Added comments explaining OSS vs SaaS deployment modes
  - Templates remain (for flexibility) but are conditional on enabled flag

- [x] **5.1.3 SaaS components isolated in OSS chart**
  - tenant-workload-operator templates exist but disabled by default
  - CRDs remain for compatibility but not deployed unless operator enabled
  - Multi-tenant features only activate when explicitly configured

### 5.2 SaaS Deployment (Multi-Tenant) - serviceradar-web/ repo

- [x] **5.2.1 Create SaaS Helm chart in serviceradar-web/**
  - Created `helm/control-plane/` chart with:
    - Chart.yaml with version 0.1.0
    - values.yaml with full tenantWorkloadOperator configuration
    - CRDs: TenantWorkloadSet, TenantWorkloadTemplate
    - templates/tenant-workload-operator.yaml (deployment, RBAC)
    - templates/tenant-workload-templates.yaml (agent-gateway, zen-consumer)
    - templates/_helpers.tpl (common labels, image helpers)
  - Created Makefile with: build-operator, docker-operator, helm-lint, helm-package
  - Go code moved to cmd/tenant-workload-operator/ with standalone go.mod

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

### 6.2 Code Cleanup Notes

- [x] **6.2.1 Multi-tenant GenServers review**
  - TenantRegistryLoader - KEEP (needed for slug resolution, works for 1 or N tenants)
  - PlatformTenantBootstrap - Not in scope (creates default tenant on startup)
  - These GenServers work correctly for both single and multi-tenant deployments

- [x] **6.2.2 tenant-workload-operator in OSS Helm**
  - Decision: DISABLED by default (not deleted)
  - Templates/CRDs remain for flexibility (operators who want to enable SaaS features)
  - Set `tenantWorkloadOperator.enabled: false` in values.yaml
  - Won't be deployed unless explicitly enabled

- [ ] **6.2.3 Simplify web-ng for single-tenant** (Future iteration)
  - Remove tenant switcher from navbar
  - Remove /admin routes that manage multiple tenants
  - Default to platform tenant context always
  - These are UI polish items, not blocking for MVP

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
