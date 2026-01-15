# tenant-isolation Spec Delta

## ADDED Requirements

### Requirement: Database-Level Tenant Isolation

Each tenant instance SHALL connect to PostgreSQL with schema-scoped credentials that only permit access to that tenant's schema.

#### Scenario: Tenant pod connects with scoped credentials
- **WHEN** a tenant instance pod (core-elx, web-ng) starts
- **THEN** it connects to CNPG using tenant-specific credentials
- **AND** the PostgreSQL user only has access to that tenant's schema
- **AND** the connection's `search_path` is set to the tenant's schema

#### Scenario: Cross-schema access prevented by database
- **WHEN** tenant-A pod attempts to query tenant-B's schema
- **THEN** PostgreSQL denies access with permission error
- **AND** the query fails without returning data

#### Scenario: Application code does not track tenant context
- **WHEN** application code executes an Ash query
- **THEN** no `tenant:` parameter is required
- **AND** the query automatically uses the connection's search_path schema

### Requirement: Control Plane Creates Schema-Scoped Users

The Control Plane SHALL create PostgreSQL users with minimal privileges scoped to a single tenant schema.

#### Scenario: Tenant provisioning creates database user
- **WHEN** Control Plane provisions a new tenant
- **THEN** it creates PostgreSQL user `tenant_{slug}_app`
- **AND** grants USAGE on the tenant's schema
- **AND** grants ALL PRIVILEGES on tables and sequences in that schema
- **AND** sets the user's default `search_path` to the tenant's schema
- **AND** stores credentials in a K8s secret

#### Scenario: Database user cannot access public schema
- **WHEN** tenant database user attempts to access public schema tables
- **THEN** PostgreSQL denies access (except for explicitly granted read-only tables)

### Requirement: Tenant Instance Code Has No Multi-Tenant Awareness

Tenant instance application code (web-ng, core-elx) SHALL NOT contain logic to access multiple tenants.

#### Scenario: No cross-tenant queries possible
- **WHEN** reviewing tenant instance codebase
- **THEN** there are no `TenantSchemas.list_schemas()` calls
- **AND** there are no functions that iterate across tenant schemas
- **AND** there is no `SystemActor.platform()` usage

#### Scenario: Ash resources have no multitenancy configuration
- **WHEN** reviewing Ash resource definitions in tenant instance
- **THEN** resources do not have `multitenancy` blocks
- **AND** resources do not track `tenant_id` redundantly (schema provides isolation)

## MODIFIED Requirements

### Requirement: Platform Admin Access

Platform administrators with special certificates SHALL have cross-tenant access for debugging and support. **This access is provided through the Control Plane, not tenant instances.**

#### Scenario: Platform admin can view all tenants
- **WHEN** user has platform admin credentials
- **THEN** the user can access tenant data through Control Plane APIs
- **AND** the Control Plane has database credentials with cross-schema access

#### Scenario: Platform admin cannot access tenant pods directly
- **WHEN** platform admin attempts to access tenant instance pod
- **THEN** access is controlled by standard authentication (JWT from Control Plane)
- **AND** the tenant pod cannot provide cross-tenant data (DB credentials are scoped)

#### Scenario: Platform admin connections logged
- **WHEN** platform admin accesses tenant resources via Control Plane
- **THEN** the access is logged with admin identity and tenant accessed
