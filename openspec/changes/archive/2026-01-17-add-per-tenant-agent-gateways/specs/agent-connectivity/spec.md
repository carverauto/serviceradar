## ADDED Requirements
### Requirement: Tenant gateway endpoint selection
Agents MUST connect to a tenant-specific gateway endpoint that resolves to the tenant's gateway pool. The endpoint MUST be delivered via onboarding/config and SHOULD be a stable DNS name.

#### Scenario: Onboarding provides tenant gateway endpoint
- **GIVEN** a tenant admin downloads an onboarding package
- **WHEN** the agent starts
- **THEN** the agent connects to the tenant-specific gateway endpoint from its config
- **AND** the endpoint matches the tenant's DNS convention

#### Scenario: Endpoint load-balances across gateway pool
- **GIVEN** the tenant gateway endpoint resolves to multiple gateway instances
- **WHEN** the agent connects
- **THEN** the connection is established to any healthy gateway in the pool
- **AND** retries can reach other instances if the first is unavailable
