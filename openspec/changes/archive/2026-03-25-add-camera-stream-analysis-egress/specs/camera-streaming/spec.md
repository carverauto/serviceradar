## ADDED Requirements
### Requirement: Relay sessions support analysis branches
The system SHALL allow analysis consumers to attach to an active camera relay session in `serviceradar_core_elx` without creating a second upstream ingest for the same camera stream profile.

#### Scenario: Analysis attaches to an already-active relay
- **GIVEN** a relay session is active for camera `cam-1` profile `high`
- **WHEN** an authorized analysis branch is started for that relay session
- **THEN** the platform SHALL attach the analysis branch to the existing relay ingest
- **AND** SHALL NOT instruct the agent to open a second camera source session

### Requirement: Analysis extraction is bounded
The system SHALL support bounded extraction policies for analysis work so processing taps can sample or transform media without unbounded resource consumption.

#### Scenario: Analysis uses sampled frames
- **GIVEN** an analysis branch is configured to extract one frame every two seconds
- **WHEN** the relay session remains active
- **THEN** the platform SHALL emit analysis inputs at that bounded rate
- **AND** SHALL NOT forward every frame when the extraction policy does not require it
