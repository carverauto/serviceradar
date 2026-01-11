## MODIFIED Requirements
### Requirement: Multi-Tenant Resource Isolation
All tenant-scoped resources SHALL enforce tenant isolation at the Ash resource level using schema-based multitenancy with tenant schema prefixes. Shared resources SHALL remain in the public schema and MUST NOT store tenant-scoped data.

#### Scenario: Tenant schema isolation applied
- **GIVEN** a user belonging to tenant A
- **WHEN** the user queries for devices
- **THEN** the query SHALL execute against schema `tenant_<tenant_slug>`
- **AND** only tenant A data SHALL be visible without manual controller filtering

#### Scenario: Platform-managed resources remain public
- **GIVEN** a user requests platform-managed identity data or platform jobs (tenants, tenant memberships, platform Oban/jobs)
- **WHEN** the query is executed
- **THEN** the query SHALL use the public schema
- **AND** tenant-scoped data (including users, tokens, and job schedules) SHALL NOT be stored in public tables

#### Scenario: Tenant job schedules are schema-isolated
- **GIVEN** a tenant schedules a job via AshOban
- **WHEN** the schedule is persisted
- **THEN** the schedule record SHALL be stored in schema `tenant_<tenant_slug>`
- **AND** no tenant job schedule data SHALL be stored in the public schema
