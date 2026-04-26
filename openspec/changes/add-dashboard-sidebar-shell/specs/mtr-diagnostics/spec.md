## ADDED Requirements

### Requirement: Dashboard MTR Overlay Summaries
The system SHALL provide read-only MTR diagnostic summaries suitable for dashboard map overlays, using existing collected diagnostics and without launching new MTR jobs when the dashboard is opened.

#### Scenario: Dashboard requests recent MTR overlay state
- **GIVEN** recent MTR traces or MTR-derived causal signals exist for dashboard-visible paths
- **WHEN** the dashboard requests MTR overlay summaries
- **THEN** the system returns path identifiers, hop/path context, latency, loss, route-change, and recency fields needed for animated overlay rendering
- **AND** raw trace details remain available through the existing MTR diagnostics surfaces

#### Scenario: Opening dashboard does not trigger probes
- **WHEN** an authenticated operator opens the dashboard
- **THEN** the system reads existing MTR diagnostic state for overlay summaries
- **AND** it does not enqueue ad-hoc, bulk, or recurring MTR jobs solely because the dashboard was opened

#### Scenario: MTR overlay data is unavailable
- **GIVEN** no recent MTR diagnostic state is available for dashboard-visible paths
- **WHEN** the dashboard requests MTR overlay summaries
- **THEN** the system returns an empty result with enough metadata for the UI to render the overlay as unavailable
