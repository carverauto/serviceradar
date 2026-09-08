## ADDED Requirements
### Requirement: Analysis detections enter observability state
The system SHALL ingest camera-analysis detections or derived findings into platform observability/event surfaces using a normalized contract.

#### Scenario: Object detection produces a normalized event
- **GIVEN** an analysis worker reports a person detection for an active relay session
- **WHEN** the result is ingested by the platform
- **THEN** the system SHALL create a normalized event or derived signal linked to the relay session and camera source
- **AND** the result SHALL be queryable through the normal observability surfaces

### Requirement: Analysis events preserve provenance
The system SHALL preserve provenance between relay sessions, analysis workers, and derived events.

#### Scenario: Operator inspects an analysis result
- **GIVEN** a derived event produced by camera analysis
- **WHEN** an operator views the result
- **THEN** the system SHALL expose the originating relay session and analysis pipeline identity
- **AND** SHALL distinguish derived analysis output from raw camera state
