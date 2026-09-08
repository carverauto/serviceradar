# tenant-gateway-fleet Specification

## Purpose
TBD - created by archiving change add-per-tenant-agent-gateways. Update Purpose after archive.
## Requirements
### Requirement: Tenant gateway pool provisioning
The system SHALL provision a tenant gateway pool in Kubernetes using a declarative control plane (CRD/operator).

#### Scenario: Tenant gateway pool created via CRD
- **GIVEN** a tenant gateway CRD is applied
- **WHEN** the operator reconciles the resource
- **THEN** a gateway Deployment/DaemonSet is created for that tenant
- **AND** the gateway instances join the shared ERTS cluster

### Requirement: Tenant gateway DNS routing
The system SHALL expose a tenant-specific gateway endpoint that routes to the tenant's gateway pool.

#### Scenario: Tenant gateway endpoint resolves
- **GIVEN** tenant "acme" has an active gateway pool
- **WHEN** the tenant gateway DNS name is resolved
- **THEN** the response points to the tenant gateway load balancer
- **AND** only tenant "acme" gateway instances are behind it

### Requirement: HA and scaling for tenant gateways
The system SHALL support multiple gateway instances per tenant and allow independent scaling per tenant.

#### Scenario: Tenant-specific scale
- **GIVEN** tenant "acme" requires additional throughput
- **WHEN** the gateway pool size is increased
- **THEN** only tenant "acme" gateway instances scale up
- **AND** other tenants are unaffected

