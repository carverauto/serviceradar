## ADDED Requirements
### Requirement: Camera analysis workers are platform-registered
The system SHALL maintain a platform-owned registry of camera analysis workers that can be targeted by relay-scoped analysis branches.

#### Scenario: A branch targets a registered worker
- **GIVEN** a camera analysis worker registered with the platform
- **WHEN** a relay-scoped analysis branch requests that worker by id
- **THEN** the platform SHALL resolve dispatch against the registered worker
- **AND** SHALL NOT require the branch to carry a raw endpoint as its only target model

### Requirement: Camera analysis workers can be selected by capability
The system SHALL support simple capability-based selection of camera analysis workers for relay-scoped branches.

#### Scenario: A branch requests a capability
- **GIVEN** multiple registered camera analysis workers
- **AND** at least one worker advertises the requested capability
- **WHEN** a relay-scoped analysis branch requests that capability
- **THEN** the platform SHALL resolve one matching worker
- **AND** SHALL surface an explicit bounded failure when no worker matches
