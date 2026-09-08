## ADDED Requirements
### Requirement: Default Docker Compose stack excludes dev-only services
The default Docker Compose stack SHALL not include dev-only services such as faker.

#### Scenario: Default stack configuration
- **WHEN** a user runs `docker compose up -d` with the default compose file
- **THEN** the faker service is not defined or started
- **AND** the stack remains production-oriented

### Requirement: Dev compose stack provides opt-in faker
The development Docker Compose configuration SHALL provide faker only when explicitly enabled via a dev compose file or overlay.

#### Scenario: Dev stack opt-in
- **WHEN** a user enables the dev compose configuration
- **THEN** the faker service is included and starts successfully
- **AND** the base compose stack remains unchanged
