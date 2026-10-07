## ADDED Requirements

### Requirement: Over-declared dashboard frames are reported
The host SHALL deliver an error frame for each dashboard data frame it declines to evaluate, and it SHALL NOT omit that frame from the delivered set.

#### Scenario: Declaring more frames than the host will run is reported
- **GIVEN** a dashboard manifest declaring more data frames than the host is willing to evaluate concurrently
- **WHEN** the dashboard is loaded
- **THEN** the frames the host declines to run SHALL be reported to the renderer as errored frames
- **AND** they SHALL NOT be silently omitted from the delivered set
- **AND** the frames the host accepts SHALL still be delivered
