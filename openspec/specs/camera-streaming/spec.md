# camera-streaming Specification

## Purpose
TBD - created by archiving change add-camera-stream-analysis-egress. Update Purpose after archive.
## Requirements
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

### Requirement: Analysis branches may dispatch to external HTTP workers
The system SHALL allow a relay-scoped analysis branch to dispatch bounded `camera_analysis_input.v1` payloads to configured external HTTP workers without creating another upstream camera pull.

#### Scenario: Relay sample is delivered to a worker
- **GIVEN** an active relay session with an attached analysis branch
- **AND** an HTTP worker is configured for that branch
- **WHEN** the branch emits a bounded analysis input
- **THEN** the platform SHALL dispatch the normalized input payload to the worker
- **AND** SHALL keep the dispatch associated with the originating relay session and branch identity

### Requirement: Analysis dispatch must remain bounded
The system SHALL bound analysis worker dispatch so relay playback and ingest remain prioritized over analysis delivery.

#### Scenario: Worker pressure exceeds dispatch limits
- **GIVEN** an active relay session with an attached analysis branch
- **AND** the configured worker is slower than the sample rate
- **WHEN** dispatch concurrency or timeout limits are exceeded
- **THEN** the platform SHALL drop or reject excess analysis work
- **AND** SHALL NOT block viewer playback or require another upstream camera pull

