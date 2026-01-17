## ADDED Requirements
### Requirement: Per-tenant gateway pools
The platform SHALL run a dedicated gateway pool per tenant, and each gateway instance SHALL register and operate only within that tenant scope.

#### Scenario: Tenant-specific gateway pool
- **GIVEN** tenant "acme" is provisioned
- **WHEN** gateway pools are created
- **THEN** at least one gateway instance is assigned to tenant "acme"
- **AND** that gateway is not eligible to serve other tenants

#### Scenario: Multi-gateway HA per tenant
- **GIVEN** tenant "acme" has two gateway instances
- **WHEN** one instance becomes unavailable
- **THEN** agent connections for tenant "acme" continue via the remaining instance
- **AND** cross-tenant traffic is never routed to the pool

### Requirement: Tenant-scoped gateway registration
Gateway registry entries SHALL include tenant identifiers and SHALL be used for tenant-scoped routing and coordination.

#### Scenario: Registry is tenant-scoped
- **WHEN** a gateway registers itself in the cluster
- **THEN** the registry entry includes the tenant identifier
- **AND** scheduling/routing queries only consider gateways for the same tenant
