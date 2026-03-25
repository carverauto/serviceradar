## ADDED Requirements
### Requirement: Worker Flapping State Transitions SHALL Emit Observability Signals
The platform SHALL emit explicit observability signals when a registered camera analysis worker enters or leaves flapping state.

#### Scenario: Worker starts flapping
- **WHEN** recomputation changes a worker from not flapping to flapping
- **THEN** the platform SHALL emit a worker flapping transition signal
- **AND** the signal SHALL include worker identity and bounded transition metadata

#### Scenario: Worker stops flapping
- **WHEN** recomputation changes a worker from flapping to not flapping
- **THEN** the platform SHALL emit a worker flapping transition signal indicating recovery
