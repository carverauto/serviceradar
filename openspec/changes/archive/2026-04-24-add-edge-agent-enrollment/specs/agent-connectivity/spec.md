## MODIFIED Requirements
### Requirement: Tenant gateway endpoint selection
Agents MUST connect to a tenant-specific gateway endpoint that resolves to the tenant's gateway pool. The endpoint MUST be delivered via onboarding/config and SHOULD be a stable DNS name. For self-hosted deployments, operators SHALL be able to configure the externally reachable gateway endpoint that is embedded in onboarding packages.

#### Scenario: Onboarding provides tenant gateway endpoint
- **GIVEN** a tenant admin downloads an onboarding package
- **WHEN** the agent starts
- **THEN** the agent connects to the tenant-specific gateway endpoint from its config
- **AND** the endpoint matches the tenant's DNS convention or configured external endpoint

#### Scenario: Endpoint load-balances across gateway pool
- **GIVEN** the tenant gateway endpoint resolves to multiple gateway instances
- **WHEN** the agent connects
- **THEN** the connection is established to any healthy gateway in the pool
- **AND** retries can reach other instances if the first is unavailable

#### Scenario: Operator-configured gateway endpoint
- **GIVEN** a self-hosted deployment with an operator-configured gateway endpoint
- **WHEN** an onboarding package is created
- **THEN** the package embeds the configured endpoint
- **AND** agents use that endpoint during enrollment
