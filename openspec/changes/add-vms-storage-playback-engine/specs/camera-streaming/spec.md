## MODIFIED Requirements

### Requirement: Viewer sessions are authorized and short-lived
The system SHALL require an authorized viewer session before exposing live camera media, and SHALL tear down the shared upstream ingest after the configured idle timeout only when no viewer, recorder or authorized analysis lease remains.

#### Scenario: Last viewer disconnects
- **GIVEN** an active relay with one viewer and no recorder or analysis lease
- **WHEN** that viewer disconnects
- **THEN** the relay SHALL become idle and close after the configured timeout unless a consumer attaches

#### Scenario: Recording outlives viewers
- **GIVEN** a recorder lease on the same camera/profile ingest
- **WHEN** the last viewer disconnects
- **THEN** recording SHALL continue without opening a second source session
- **AND** a later viewer SHALL attach to the existing ingest

#### Scenario: Consumer overload is isolated
- **WHEN** recording or optional analysis exceeds its admitted budget
- **THEN** the system SHALL expose its gap or rejected work
- **AND** SHALL preserve unrelated live viewer sessions and bounded resource use
