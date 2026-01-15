# Change: Break out Tenant/SaaS Control Plane

## Why
The current architecture conflates the SaaS control plane with the tenant runtime, leading to complexity in `core-elx` where it possesses "super power" access over the entire database. This violates strict tenant isolation boundaries and complicates the codebase with mixed multi-tenant logic.

By breaking out the control plane, we ensure that:
1.  **Strict Isolation:** Every tenant gets their own `core-elx` and `web-ng` logical (or physical) instance.
2.  **Reduced Complexity:** `core-elx` no longer needs complex multi-tenant policies to protect data; it only sees its own tenant's data.
3.  **Security:** Tenants connect to shared resources (NATS, CNPG) using restricted credentials (JWTs) that only allow access to their specific scope.
4.  **Parity:** The OSS version effectively becomes a "single tenant" deployment of this architecture, simplifying the mental model.

## What Changes

### Architecture Split
- **Control Plane**: A new or refactored service responsibility that manages tenant lifecycles, global NATS accounts, and CNPG database provisioning. It does *not* handle tenant runtime traffic.
- **Tenant Instance**: A dedicated set of services (`core-elx`, `web-ng`) for *each* tenant.
    - Connects to NATS with a tenant-specific JWT.
    - Connects to CNPG with tenant-specific credentials restricted to its schema.
- **Shared Infrastructure**:
    - **NATS**: Utilizes Account/User JWTs to enforce isolation.
    - **CNPG**: Hosting multiple tenant schemas, but access is strictly gatekept by database roles/users.

### Identity & Membership (Control Plane)
- **Centralized Authority**: `Tenant`, `User`, and `TenantMembership` resources move exclusively to the **Control Plane**.
- **TenantMembership Strategy**:
    - The "Attribute-based" multitenancy strategy for `TenantMembership` is removed from the Tenant Instance code.
    - Authorization is derived from **JWT Claims** issued by the Control Plane.
    - The Tenant Instance (`core-elx`) trusts the JWT signature and roles (e.g., `role: admin`, `tenant_id: <uuid>`) without needing to query a local `TenantMembership` table.
- **System Actor Elimination**:
    - The `system_actor` bypass (God Mode) is deprecated.
    - Internal background jobs (e.g., `Edge.Workers`) must operate within a specific Tenant Context, using a service account or specific token for that tenant, rather than a global superuser.
    - Refactor `ServiceRadarWebNG.Infrastructure` to remove "no actor" fallbacks. Explicit authorization is required for every call.

### Codebase Refactoring (`core-elx` & `web-ng`)
- **Ash Multitenancy**:
    - Remove "attribute-based" multitenancy logic where it bleeds across boundaries.
    - Standardize on `strategy :context` (Schema-based) but strictly enforced by the DB connection/role, not just application logic.
    - Audit and refactor `ServiceRadarWebNG.Infrastructure` and `AshTenant` to remove "system actor" bypasses and enforce strict scope usage.
- **Dependency Cleanup**:
    - Identify and sever links where `web-ng` or `core-elx` assumes it can access "all tenants".

## Impact
- **Specs**: Overrides or supersedes parts of `enforce-tenant-schema-isolation` by taking it to a full architectural split.
- **Code**: Significant refactoring in `elixir/serviceradar_core` and `web-ng`.
- **Ops**: Deployment model changes. Kubernetes manifests will need to support deploying "Tenant Stacks" dynamically or templated.

### Standalone & Helm Support (Single Tenant)
To ensure the OSS/Standalone version remains easy to deploy (zero-touch), we will introduce a **Platform Bootstrap** mechanism within the Helm chart.
- **Goal**: Automatically provision the environment for a single "Platform Tenant" without requiring an external Control Plane UI.
- **Mechanism**: A Helm `post-install` / `post-upgrade` Job (or a dedicated bootstrap container).
- **Bootstrap Actions**:
    1.  **Initialize Identity**: Create the default "Platform Tenant" and the initial Admin User (credentials via Secret/Values).
    2.  **Provision Resources**: Call the Control Plane APIs (or internal logic) to provision the NATS account and CNPG schema for this default tenant.
    3.  **Configure Runtime**: Inject the generated Tenant ID and Keys into the `web-ng` and `core-elx` configuration, effectively "pinning" them to this single tenant.
- **Outcome**: The user runs `helm install`, and the system boots up fully configured as a single-tenant instance of the multi-tenant architecture.

### Implementation Plan (Draft)

1.  **Deep Dive Analysis**:
    - Scan `core-elx` and `web-ng` for all `multitenancy` configurations.
    - Map out the "God Mode" code paths in `core-elx` that currently manage all tenants.
2.  **Prototype Isolation**:
    - Create a POC where `core-elx` is started with restricted CNPG credentials.
    - Verify NATS JWT authentication for a single tenant.
3.  **Refactor Ash Resources**:
    - Update `Ash.Resource` definitions to assume they are running *within* a tenant context, removing global visibility where possible.
4.  **Control Plane Implementation**:
    - Define the API for the Control Plane (Create Tenant -> Provision DB User -> Issue NATS JWT -> Spin up/Configure Tenant Stack).

## Open Questions
- How do we handle "Platform Admin" features that need to see across tenants? (Likely a separate aggregation service or specific Control Plane API, rather than a "super user" in a tenant app).
- Resource overhead of running separate `core-elx`/`web-ng` processes per tenant vs. logical separation within the VM. (Proposal leans towards logical separation enforced by strict strict credentials/middleware, or full physical separation if resources allow).
