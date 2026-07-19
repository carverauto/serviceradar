## ADDED Requirements

### Requirement: Explainable Anomaly Episode Lifecycle
The operator UI SHALL distinguish an anomaly episode's opening trigger from its current lifecycle state and resolution reason. A cleared episode MUST NOT present an opening breach message as though the breach remains active. Engine-specific clear reasons SHALL be translated into plain operator language with access to lifecycle documentation.

#### Scenario: Cleared episode is displayed
- **GIVEN** an anomaly episode has a cleared lifecycle state
- **WHEN** an operator opens its detail modal
- **THEN** the UI SHALL identify the episode as resolved
- **AND** it SHALL show the resolution reason separately from the original detection trigger

#### Scenario: Flap-merged episode is displayed
- **GIVEN** an episode's clear reason is `flap_merged`
- **WHEN** an operator views the episode
- **THEN** the UI SHALL explain that a brief clear and reopen were grouped into one incident
- **AND** it SHALL state whether the incident is currently resolved
- **AND** it SHALL provide a link to anomaly lifecycle documentation
