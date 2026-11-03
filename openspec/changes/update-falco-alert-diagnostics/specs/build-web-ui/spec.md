## ADDED Requirements

### Requirement: Event detail UI SHALL expose Falco runtime diagnostics
The web UI SHALL display normalized Falco runtime diagnostic context on the runtime security occurrence and its finding without requiring operators to inspect raw JSON.
Raw evidence for that occurrence is the viewer specified by `add-falco-runtime-findings`. This requirement does not show the raw payload from a promoted OCSF event.

#### Scenario: Operator inspects a Falco occurrence
- **GIVEN** a Falco occurrence includes normalized process, command, cwd, executable flags, container, host, and Kubernetes attribution fields
- **WHEN** an operator opens the occurrence or its finding detail
- **THEN** the UI SHALL display those fields in a structured diagnostic section
- **AND** raw payload access SHALL follow the occurrence evidence viewer in `add-falco-runtime-findings`

#### Scenario: Kubernetes attribution is partial
- **GIVEN** a Falco occurrence includes a container id and host but no Kubernetes pod or namespace
- **WHEN** an operator opens the occurrence or its finding detail
- **THEN** the UI SHALL clearly show that Kubernetes attribution is partial or missing
- **AND** it SHALL still show the available host, container id, process, command, and cwd context

### Requirement: Alert detail UI SHALL explain stateful security incidents
The web UI SHALL display stateful security alert diagnostic summaries so operators can determine what fired, why it fired, and what source events contributed.

#### Scenario: Operator inspects a Falco stateful alert
- **GIVEN** a Falco-derived stateful alert includes rule, grouping, threshold window, occurrence count, first/last seen, representative source events, and top process/container samples
- **WHEN** an operator opens the alert detail view
- **THEN** the UI SHALL display the rule and grouping summary, threshold/window summary, occurrence summary, source provenance, and representative runtime samples
- **AND** the UI SHALL link or otherwise identify representative source events when source ids are available

#### Scenario: Historical alert lacks enriched diagnostics
- **GIVEN** an older alert does not include the enriched diagnostic summary
- **WHEN** an operator opens the alert detail view
- **THEN** the UI SHALL render available metadata and raw payload sections without failing
- **AND** it SHALL indicate that structured diagnostics are unavailable for that alert
