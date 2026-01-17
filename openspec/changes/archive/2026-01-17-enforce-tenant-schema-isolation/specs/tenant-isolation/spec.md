## ADDED Requirements
### Requirement: Schema-Per-Tenant Data Isolation
The system SHALL create a dedicated PostgreSQL schema for each tenant and store all tenant-scoped data exclusively within that schema.

#### Scenario: Tenant schema created on provisioning
- **WHEN** a tenant is created
- **THEN** a schema named `tenant_<tenant_slug>` SHALL be created
- **AND** tenant migrations SHALL be applied to that schema before the tenant is usable

#### Scenario: Platform tenant uses its own schema
- **WHEN** the platform tenant is provisioned
- **THEN** the schema `tenant_platform` SHALL exist
- **AND** platform tenant data SHALL be stored in that schema, not public
