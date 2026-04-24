## ADDED Requirements
### Requirement: Canonical Directional Edge Query Shape
The system SHALL project and query canonical topology edges from AGE in a render-ready directional format for GodView.

#### Scenario: AGE returns render-ready directional fields
- **GIVEN** canonical topology edges have been reconciled from mapper evidence
- **WHEN** GodView requests topology edges
- **THEN** each edge result includes `source`, `target`, `if_index_ab`, `if_index_ba`
- **AND** includes directional telemetry fields `flow_pps_ab`, `flow_pps_ba`, `flow_bps_ab`, `flow_bps_ba`
- **AND** includes `capacity_bps`, `telemetry_eligible`, and evidence metadata fields used for diagnostics

### Requirement: Reconciler-Owned Edge Arbitration
The system SHALL perform protocol/confidence arbitration for competing edge evidence before persisting/querying canonical AGE edges.

#### Scenario: Competing evidence is resolved in backend
- **GIVEN** multiple evidence records describe the same device pair (for example LLDP, CDP, SNMP-L2, UniFi)
- **WHEN** reconciliation runs
- **THEN** backend selects the canonical edge variant using deterministic arbitration rules
- **AND** AGE stores only the canonical edge for GodView consumption
- **AND** arbitration reason metadata is retained for diagnostics
