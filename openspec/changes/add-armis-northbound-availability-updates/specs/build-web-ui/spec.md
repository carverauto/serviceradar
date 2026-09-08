## ADDED Requirements

### Requirement: Armis integrations expose northbound scheduling controls
The Settings -> Network -> Integrations UI SHALL allow operators to configure northbound Armis update behavior for Armis sources.

#### Scenario: Operator configures Armis northbound cadence
- **GIVEN** an operator is editing an Armis integration source
- **WHEN** they enable northbound updates
- **THEN** the UI SHALL allow them to configure the update cadence/schedule
- **AND** the UI SHALL persist the configuration in the database

#### Scenario: Non-Armis integration does not show Armis northbound settings
- **GIVEN** an operator is editing a non-Armis integration source
- **WHEN** the form is rendered
- **THEN** Armis-specific northbound schedule controls SHALL NOT be shown

### Requirement: Integrations UI distinguishes inbound sync from northbound updates
The integrations UI SHALL display inbound discovery status and northbound Armis update status as separate runtime surfaces.

#### Scenario: Discovery healthy but northbound unhealthy
- **GIVEN** an Armis integration source has a successful discovery status
- **AND** its latest northbound update run failed
- **WHEN** the operator views the integrations list or detail page
- **THEN** the UI SHALL show discovery as healthy
- **AND** SHALL separately show northbound update failure state, timestamp, and error summary

### Requirement: Operators can inspect and trigger northbound runs
The UI SHALL expose recent Armis northbound run history and provide a manual run action for supported sources.

#### Scenario: Operator runs Armis northbound update on demand
- **GIVEN** an enabled Armis integration source with northbound updates configured
- **WHEN** the operator clicks "Run now"
- **THEN** the system SHALL enqueue or trigger a northbound update job
- **AND** the UI SHALL reflect the pending/running state

#### Scenario: Operator reviews recent northbound history
- **GIVEN** recent Armis northbound runs exist
- **WHEN** the operator opens the source detail or related jobs view
- **THEN** the UI SHALL show recent run outcomes with timestamps and counts
