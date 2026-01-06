## MODIFIED Requirements
### Requirement: Multi-Tenant Resource Isolation
All tenant-scoped resources SHALL enforce tenant isolation at the Ash resource level using schema-based multitenancy with tenant schema prefixes. Shared resources SHALL remain in the public schema and MUST NOT store tenant-scoped data.

#### Scenario: Tenant schema isolation applied
- **GIVEN** a user belonging to tenant A
- **WHEN** the user queries for devices
- **THEN** the query SHALL execute against schema `tenant_<tenant_slug>`
- **AND** only tenant A data SHALL be visible without manual controller filtering

#### Scenario: Platform-managed resources remain public
- **GIVEN** a user requests platform-managed identity data (tenants, users, tenant memberships)
- **WHEN** the query is executed
- **THEN** the query SHALL use the public schema
- **AND** tenant-scoped data SHALL NOT be stored in public tables
