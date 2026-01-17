# Deployment Isolation Spec Delta

## ADDED Requirements

### Requirement: Database-Level Account Isolation

Each deployment instance SHALL connect to PostgreSQL with schema-scoped credentials that only permit access to that instance's schema.

#### Scenario: Instance pod connects with scoped credentials
- **WHEN** a deployment instance pod (core-elx, web-ng) starts
- **THEN** it connects to CNPG using deployment-scoped credentials
- **AND** the PostgreSQL user only has access to that instance's schema
- **AND** the connection's `search_path` is set to that schema

#### Scenario: Cross-schema access prevented by database
- **WHEN** account-A pod attempts to query account-B's schema
- **THEN** PostgreSQL denies access with permission error
- **AND** the query fails without returning data

#### Scenario: Application code does not track schema context
- **WHEN** application code executes an Ash query
- **THEN** no explicit schema context parameter is required
- **AND** the query automatically uses the connection's search_path schema

### Requirement: Control Plane Creates Schema-Scoped Users

The Control Plane SHALL create PostgreSQL users with minimal privileges scoped to a single account schema.

#### Scenario: Account provisioning creates database user
- **WHEN** Control Plane provisions a new account
- **THEN** it creates PostgreSQL user `account_{slug}_app`
- **AND** grants USAGE on the account's schema
- **AND** grants ALL PRIVILEGES on tables and sequences in that schema
- **AND** sets the user's default `search_path` to the account's schema
- **AND** stores credentials in a K8s secret

#### Scenario: Database user cannot access public schema
- **WHEN** account database user attempts to access public schema tables
- **THEN** PostgreSQL denies access (except for explicitly granted read-only tables)

### Requirement: Instance Code Has No Multi-Account Awareness

Instance application code (web-ng, core-elx) SHALL NOT contain logic to access multiple accounts.

#### Scenario: No cross-account queries possible
- **WHEN** reviewing instance codebase
- **THEN** there are no `TenantSchemas.list_schemas()` calls
- **AND** there are no functions that iterate across schemas
- **AND** there is no `SystemActor.platform()` usage

#### Scenario: Ash calls do not pass schema context
- **WHEN** reviewing Ash operations in instance code
- **THEN** there are no explicit schema context parameters passed
- **AND** queries rely on the connection's search_path schema

## MODIFIED Requirements

### Requirement: Platform Admin Access

Platform administrators with special certificates SHALL have cross-account access for debugging and support. **This access is provided through the Control Plane, not deployment instances.**

#### Scenario: Platform admin can view all accounts
- **WHEN** user has platform admin credentials
- **THEN** the user can access account data through Control Plane APIs
- **AND** the Control Plane has database credentials with cross-schema access

#### Scenario: Platform admin cannot access instance pods directly
- **WHEN** platform admin attempts to access a deployment instance pod
- **THEN** access is controlled by standard authentication (JWT from Control Plane)
- **AND** the instance pod cannot provide cross-account data (DB credentials are scoped)

#### Scenario: Platform admin connections logged
- **WHEN** platform admin accesses account resources via Control Plane
- **THEN** the access is logged with admin identity and account accessed
