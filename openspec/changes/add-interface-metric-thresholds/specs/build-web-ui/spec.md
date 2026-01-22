## ADDED Requirements
### Requirement: Per-metric threshold controls in interface metrics UI
The interface metrics UI SHALL provide per-metric enable/disable controls and threshold settings within each metric card.

#### Scenario: Per-metric controls shown
- **GIVEN** a device interface with available metrics
- **WHEN** a user opens the interface details view
- **THEN** each metric card SHALL include an explicit enable/disable control
- **AND** threshold controls for that metric

#### Scenario: Controls gated by metric enablement
- **GIVEN** a metric card with thresholds configured
- **WHEN** the metric is disabled
- **THEN** threshold controls SHALL be disabled or hidden

#### Scenario: Control interaction does not toggle selection inadvertently
- **GIVEN** the user clicks a threshold input or toggle
- **WHEN** the input changes
- **THEN** only the intended control action SHALL occur (no unintended selection toggle)
