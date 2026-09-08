## ADDED Requirements
### Requirement: Worker notification audit state reuses routed alerts
The platform SHALL derive camera analysis worker notification audit state from the existing routed worker alert and standard alert lifecycle rather than a parallel worker notification model.

#### Scenario: Audit state comes from standard alert lifecycle
- **WHEN** the platform needs notification audit state for a worker alert
- **THEN** it SHALL resolve that state from the routed worker alert's corresponding standard alert record
- **AND** it SHALL NOT persist a separate worker notification record
