## ADDED Requirements

### Requirement: Rule builder SHALL expose incident grouping and suppression controls
The system SHALL allow operators to configure event-derived alert incident behavior through the rules UI using grouping, cooldown, and renotify controls.

#### Scenario: Operator edits grouping keys for a security alert policy
- **GIVEN** an operator is configuring an event-derived alert policy in the rules UI
- **WHEN** the operator sets incident grouping keys for the policy
- **THEN** the saved policy SHALL persist those grouping keys
- **AND** subsequent matching events SHALL use those keys when deciding whether to create a new incident or update an existing one

#### Scenario: Operator changes cooldown and renotify behavior
- **GIVEN** an operator is configuring an event-derived alert policy in the rules UI
- **WHEN** the operator updates `cooldown_seconds` or `renotify_seconds`
- **THEN** the saved policy SHALL persist those values
- **AND** notification suppression and repeat notification behavior SHALL follow the configured values

### Requirement: Rules UI SHALL expose default incident behavior for Falco-style security detections
The system SHALL surface the default incident alert behavior used for Falco-style security detections through an operator-editable rules experience.

#### Scenario: Operator reviews the default Falco/security incident policy
- **GIVEN** Falco-derived alerts are enabled
- **WHEN** an operator opens the rules UI for event-derived alert behavior
- **THEN** the operator SHALL be able to inspect the default grouping, cooldown, and renotify settings applied to Falco-style detections
- **AND** the operator SHALL be able to change those settings without editing raw code or JSON outside the supported UI
