## ADDED Requirements
### Requirement: Reconciler Ownership of Edge Telemetry Attribution
Network discovery reconciliation SHALL compute and persist directional edge telemetry attribution for canonical topology edges as backend-owned state.

#### Scenario: Reconciler attributes telemetry to both edge directions
- **GIVEN** interface telemetry is available for both canonical edge endpoints
- **WHEN** reconciliation runs
- **THEN** backend computes and persists both `ab` and `ba` directional telemetry values
- **AND** marks the edge telemetry source as interface-attributed

#### Scenario: Reconciler persists one-sided telemetry with diagnostics
- **GIVEN** only one endpoint has usable interface telemetry for a canonical edge
- **WHEN** reconciliation runs
- **THEN** backend persists the available directional side and zero/defaults the missing side per contract
- **AND** emits diagnostics identifying one-sided attribution

### Requirement: Web Layer Must Not Recompute Canonical Edge Telemetry
The system SHALL not compute canonical edge telemetry in web presentation code once backend canonical telemetry projection is enabled.

#### Scenario: GodView consumes backend telemetry as pass-through
- **GIVEN** runtime graph rows include canonical edge telemetry fields
- **WHEN** GodView snapshot generation runs
- **THEN** web-ng uses backend-provided edge telemetry values directly
- **AND** web-ng does not query `timeseries_metrics` to derive edge telemetry
