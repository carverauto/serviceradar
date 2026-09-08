## ADDED Requirements

### Requirement: Falco findings are complete structured security findings

Every ingested Falco event SHALL be promoted to a structured OCSF finding
regardless of severity (severity is a filter, not a gate for analytics
visibility); the stateful-alert gate remains separate. Findings SHALL resolve
a Falco rule to an OCSF finding class via a maintained rule→class map
(defaulting to Detection Finding 2004), and SHALL carry a stable finding
identity so re-fired rules correlate to one logical finding rather than a new
record per occurrence.

#### Scenario: Low-severity Falco event is a queryable finding
- **WHEN** a Falco event with priority notice/info is ingested
- **THEN** it SHALL appear in `in:security_findings source:falco`
- **AND** severity SHALL be usable as a filter, not a precondition for visibility

#### Scenario: Rule maps to its OCSF class
- **GIVEN** a Falco rule mapped to a non-default OCSF finding class
- **WHEN** its event is promoted
- **THEN** the finding SHALL carry the mapped class_uid (default 2004 when unmapped)

#### Scenario: Re-fired rule correlates to one finding
- **WHEN** the same rule fires repeatedly for the same key dimensions
- **THEN** the events SHALL share a stable finding identity for grouping/dedup
