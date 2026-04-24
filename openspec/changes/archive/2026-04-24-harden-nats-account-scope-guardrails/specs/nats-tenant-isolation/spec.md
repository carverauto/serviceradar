## MODIFIED Requirements
### Requirement: NATS Account Isolation

Enterprise tenants with collector deployments SHALL receive dedicated NATS accounts for message isolation.

Each tenant account SHALL:
- Have unique credentials (NKey or JWT)
- Be limited to publishing/subscribing to their prefixed subjects
- Support leaf node connections from customer networks
- Reject signed imports, exports, subject mappings, or user permission overrides that escape the tenant or approved platform scope
- Use finite JetStream resource limits instead of unlimited default quotas

#### Scenario: Cross-tenant authority widening is rejected
- **GIVEN** a caller requests a signed account JWT or user credential override for tenant `acme-corp`
- **WHEN** the request includes publish, subscribe, import, export, or mapping subjects outside `acme-corp` or approved platform subjects
- **THEN** the signing request SHALL be rejected
- **AND** no JWT with widened cross-tenant authority is returned

#### Scenario: New account receives bounded JetStream quotas
- **GIVEN** the platform signs a new tenant account without explicit JetStream quota overrides
- **WHEN** the account JWT is created
- **THEN** the JetStream limits in the account claims SHALL be finite
- **AND** the account SHALL NOT receive unlimited memory, disk, stream, or consumer quotas by default
