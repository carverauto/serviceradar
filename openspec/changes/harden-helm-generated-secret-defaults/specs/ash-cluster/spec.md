## ADDED Requirements
### Requirement: Helm installs use unique cluster cookies by default
Helm installs SHALL generate a unique Erlang distribution cookie per install when the operator does not provide an explicit override, and the chart SHALL NOT template a fixed default cluster cookie into runtime pods.

#### Scenario: Generated cookie on default install
- **GIVEN** the Helm chart is installed without an explicit cluster cookie override
- **WHEN** the release renders and the secret-generation hook runs
- **THEN** a unique cluster cookie SHALL be generated for that install
- **AND** core, web-ng, and agent-gateway SHALL consume that generated value

#### Scenario: Explicit override remains supported
- **GIVEN** the operator provides an explicit cluster cookie override
- **WHEN** the release renders
- **THEN** the chart SHALL use the operator-provided value
- **AND** it SHALL NOT replace it with a generated cookie
