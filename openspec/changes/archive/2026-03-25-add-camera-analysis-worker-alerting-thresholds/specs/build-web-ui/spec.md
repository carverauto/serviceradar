## ADDED Requirements
### Requirement: Camera Analysis Worker Ops SHALL Show Summarized Alert State
The authenticated camera analysis worker management surface SHALL show summarized worker alert state when bounded degradation thresholds are active.

#### Scenario: Worker has an active alert
- **WHEN** an operator views a worker with an active thresholded alert state
- **THEN** the worker surface SHALL display that alert state prominently
- **AND** it SHALL show enough normalized context to explain the active alert

#### Scenario: Worker has no active alert
- **WHEN** an operator views a worker without an active thresholded alert state
- **THEN** the worker surface SHALL indicate that no thresholded alert is active
