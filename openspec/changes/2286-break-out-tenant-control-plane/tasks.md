# Tasks: Break out Tenant/SaaS Control Plane

- [ ] **Analysis & Design**
  - [x] Initial scan of `system_actor` usage (Found in `TenantResolver`, `Inventory`, `Edge.Onboarding*`, `Infrastructure`).
  - [ ] Deep dive into `elixir/serviceradar_core` and `web-ng` to inventory all multi-tenant Ash resources.
  - [ ] Identify "God Mode" calls in `core-elx` that violate single-tenant isolation.
  - [ ] Design the NATS JWT hierarchy for tenant isolation.
  - [ ] Design the CNPG role/schema security model.
  - [ ] **Architecture Decision**: finalize JWT claim structure to support stateless authorization in Tenant Instances (replacing local `TenantMembership` lookups).

- [ ] **Refactoring: Identity & Control Plane**
  - [ ] Move `Tenant`, `User`, `TenantMembership` Ash resources to the Control Plane application.
  - [ ] Update `ServiceRadar.Identity` to rely on JWT claims for authorization in the Tenant Instance.
  - [ ] Implement a "Service Account" or "Tenant Token" mechanism for background workers (replacing `system_actor`).

- [ ] **Refactoring: Web-NG & Edge**
  - [ ] **CRITICAL**: Remove `system_actor` definition and fallbacks from `ServiceRadarWebNG.Infrastructure`.
  - [ ] Refactor `TenantResolver` to extract tenant context strictly from domains/tokens.
  - [ ] Refactor `Edge.OnboardingPackages` and `OnboardingEvents` to require explicit tenant context.
  - [ ] Update `AshTenant` (Scope) to strictly require tenant context from the environment/config.
  - [ ] Remove cross-tenant access patterns from Ash resources.

- [ ] **Infrastructure & Control Plane**
  - [ ] Implement NATS Operator/Account/User JWT generation in the Control Plane.
  - [ ] Implement CNPG user provisioning with restricted schema access.
  - [ ] Create the "Control Plane" service logic (separation from `core-elx`).

- [ ] **Helm & Bootstrap**
  - [ ] Create a `platform-bootstrap-job` in Helm.
  - [ ] Implement logic to auto-create the default Platform Tenant and Admin User on first run.
  - [ ] Ensure the bootstrap job configures the `core-elx`/`web-ng` deployment with the single-tenant context (Tenant ID, NATS Creds).
  - [ ] Verify `helm install` results in a working system with `web-ng` accessible and `core-elx` processing data for the default tenant.