## ADDED Requirements
### Requirement: Per-metric interface thresholds
The system SHALL store per-metric threshold settings for interface metrics, keyed by metric name, including comparison, value, duration, severity, and enabled state.

#### Scenario: Persist per-metric threshold
- **GIVEN** a user configures threshold settings for metric `ifInOctets`
- **WHEN** the interface settings are saved
- **THEN** the device inventory SHALL persist a threshold entry keyed by `ifInOctets`
- **AND** the entry SHALL include comparison, value, duration, severity, and enabled fields

#### Scenario: Read per-metric thresholds
- **GIVEN** an interface with stored per-metric thresholds
- **WHEN** the interface settings are retrieved
- **THEN** the response SHALL include the per-metric threshold map
