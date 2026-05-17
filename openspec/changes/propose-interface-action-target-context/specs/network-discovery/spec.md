## ADDED Requirements

### Requirement: Topology backbone island diagnostics
The topology pipeline SHALL expose enough diagnostics to explain why backbone devices that have recent link evidence are rendered as separate connected components.

Diagnostics SHALL distinguish missing link ingestion, canonical device identity drift, alias merge/split effects, filtered edge evidence, missing interface attribution, and frontend visibility/grouping decisions.

#### Scenario: Backbone expected as one connected component
- **GIVEN** recent mapper or topology evidence links multiple backbone devices
- **WHEN** the topology view renders those devices as separate islands
- **THEN** ServiceRadar SHALL provide diagnostics identifying which expected links were absent or filtered
- **AND** the diagnostics SHALL include the reason category for each dropped or missing edge when known

#### Scenario: Edge hidden by filter or confidence rule
- **GIVEN** a topology edge exists in persisted evidence
- **AND** the topology read model or frontend hides it due to confidence, role, interface attribution, or visibility filtering
- **WHEN** an operator inspects topology diagnostics
- **THEN** the diagnostics SHALL report that the edge exists but was hidden
- **AND** it SHALL include the applied rule or missing field that caused the edge to be excluded
