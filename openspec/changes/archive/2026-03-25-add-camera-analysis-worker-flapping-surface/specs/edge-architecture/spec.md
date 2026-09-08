## ADDED Requirements
### Requirement: Camera Analysis Workers SHALL Derive Flapping State
The platform SHALL derive a bounded flapping state for each registered camera analysis worker from recent probe history.

#### Scenario: Worker meets flapping threshold
- **WHEN** a worker's recent probe history contains enough healthy/unhealthy transitions to meet the configured threshold
- **THEN** the worker SHALL be marked as flapping
- **AND** the derived flapping metadata SHALL include the transition count and bounded history window size

#### Scenario: Worker falls below flapping threshold
- **WHEN** newer probe results reduce the transition count below the configured threshold
- **THEN** the worker SHALL no longer be marked as flapping

### Requirement: Camera Analysis Worker Flapping SHALL Be Recomputed On Probe Updates
The platform SHALL recompute worker flapping state whenever recent probe history changes through active probing or dispatch-driven health updates.

#### Scenario: Probe update changes flapping state
- **WHEN** a probe result is recorded on a worker
- **THEN** the platform SHALL recompute flapping state from the bounded recent probe history
- **AND** the stored worker record SHALL reflect the updated flapping state
