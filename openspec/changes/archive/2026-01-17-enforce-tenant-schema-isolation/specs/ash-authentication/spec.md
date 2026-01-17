## ADDED Requirements
### Requirement: Tenant-Aware Authentication Context
Authentication flows SHALL resolve tenant context from vanity domains when present. If no tenant is resolved and more than one tenant exists or no default tenant is configured, the system SHALL require an explicit tenant selection. The resolved tenant MUST be stored in session state and used to scope all authentication actions (magic link, password, and token validation). Single-tenant installations SHALL auto-select the default tenant without prompting.

#### Scenario: Vanity domain resolves tenant context
- **GIVEN** a request is made to a tenant-specific host (vanity domain)
- **WHEN** the login page is accessed
- **THEN** the system SHALL resolve the tenant from the host
- **AND** authentication actions SHALL be scoped to that tenant without prompting

#### Scenario: Multi-tenant login requires tenant selection
- **GIVEN** multiple tenants exist or no default tenant is set
- **WHEN** a user accesses the login page without a tenant-resolving host
- **THEN** the system SHALL prompt for a tenant slug or selection
- **AND** the selected tenant SHALL be stored in session and used for subsequent authentication actions

#### Scenario: Single-tenant login auto-selects default tenant
- **GIVEN** a default tenant is configured and only one tenant exists
- **WHEN** a user accesses the login page without a tenant-resolving host
- **THEN** the system SHALL not prompt for tenant selection
- **AND** the default tenant SHALL be used for authentication actions
