## ADDED Requirements

### Requirement: Declarative agent config dependency catalog
The system SHALL maintain a declarative catalog of resources whose create, update, or destroy actions can affect agent-delivered configuration.

#### Scenario: Integration source declares sync config dependency
- **GIVEN** an `IntegrationSource` is assigned to an agent
- **AND** the source contributes to the `sync` portion of the agent config response
- **WHEN** the dependency catalog is inspected
- **THEN** it SHALL include an entry for `IntegrationSource`
- **AND** the entry SHALL declare the sync config type, affected-agent resolver, compiler/generator dependency, lifecycle actions, and secret diagnostics policy

#### Scenario: Missing dependency fails validation
- **GIVEN** a config generator reads an Ash resource to build agent-delivered config
- **WHEN** catalog validation runs
- **THEN** validation SHALL fail if that resource has no matching catalog entry
- **AND** the failure SHALL name the resource and config generator that require an entry

### Requirement: Catalog-driven config invalidation and push
The system SHALL use the dependency catalog to invalidate compiled agent config and notify connected agents when cataloged resources change.

#### Scenario: Armis credentials update triggers affected agent sync config refresh
- **GIVEN** an enabled Armis `IntegrationSource` assigned to agent `agent-a`
- **AND** the source has credentials used by the sync config generator
- **WHEN** an operator updates the source credentials through the UI
- **THEN** the catalog dispatcher SHALL mark `agent-a` sync config as changed
- **AND** connected sessions for `agent-a` SHALL be prompted to refresh config according to the catalog entry strategy
- **AND** unrelated agents SHALL NOT be prompted solely because of this source update

#### Scenario: Global resource update can target all affected agents
- **GIVEN** a cataloged resource affects all online agents
- **WHEN** that resource is updated
- **THEN** the catalog dispatcher SHALL use the entry's affected-agent resolver to enumerate the target agents
- **AND** SHALL invalidate or push only the config types declared by the entry

### Requirement: Agent config dependency diagnostics
The system SHALL provide diagnostics for catalog-driven config changes without exposing secret values.

#### Scenario: Operator inspects saved integration config effect
- **GIVEN** an operator saves an integration source that affects agent sync config
- **WHEN** they inspect the resource or related diagnostics
- **THEN** the system SHALL show that the source affects sync config
- **AND** SHALL show the affected agent count or affected agent identifiers when authorized
- **AND** SHALL show the resulting config version or hash when available
- **AND** SHALL redact credential values while indicating whether required secrets are present

#### Scenario: Secret values are excluded from diagnostics
- **GIVEN** a cataloged config dependency includes credential fields
- **WHEN** the system logs, displays, or exports dependency diagnostics
- **THEN** API keys, secret keys, passwords, tokens, and private keys SHALL NOT appear in plaintext
- **AND** diagnostics MAY include redacted field names, presence booleans, or non-reversible fingerprints
