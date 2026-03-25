## ADDED Requirements
### Requirement: Camera Analysis Worker Ops SHALL Show Flapping State
The authenticated camera analysis worker operator surface SHALL show derived worker flapping state alongside health and recent probe activity.

#### Scenario: Worker is flapping
- **WHEN** an operator views a worker whose derived flapping state is true
- **THEN** the surface SHALL display a visible flapping label
- **AND** it SHALL show the bounded transition count or equivalent flapping context

#### Scenario: Worker is stable
- **WHEN** an operator views a worker whose derived flapping state is false
- **THEN** the surface SHALL not display the worker as flapping

### Requirement: Camera Analysis Worker API SHALL Expose Flapping Metadata
The authenticated worker management API SHALL expose derived flapping state and normalized flapping metadata.

#### Scenario: API returns worker flapping metadata
- **WHEN** a client reads one or more registered camera analysis workers
- **THEN** each worker response SHALL include flapping state
- **AND** the response SHALL include enough bounded metadata to explain why the worker is or is not considered flapping
