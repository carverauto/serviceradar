## ADDED Requirements
### Requirement: Backend-Owned GodView Edge Contract
Network discovery ingestion and reconciliation SHALL emit a canonical topology edge contract for GodView without requiring frontend topology inference.

#### Scenario: Canonical edges are emitted from backend
- **GIVEN** discovery evidence has been ingested
- **WHEN** the reconciliation/projection pipeline completes
- **THEN** backend emits canonical edges with directional interface attribution and directional telemetry
- **AND** frontend receives these canonical edges directly from backend stream/query payloads

### Requirement: Frontend Must Not Infer Topology Structure
The system SHALL not rely on frontend pair-candidate selection or interface-attribution inference to determine topology edge structure for GodView.

#### Scenario: Frontend consumes backend topology as-is
- **GIVEN** a GodView snapshot payload produced by backend
- **WHEN** frontend builds render data
- **THEN** frontend does not run protocol arbitration or pair-candidate selection for topology structure
- **AND** frontend does not infer missing interface attribution for edge directionality
- **AND** frontend only performs rendering/layout concerns on backend-provided edges
