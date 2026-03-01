## ADDED Requirements
### Requirement: Plugin-discovered camera stream enrichment
The system SHALL persist plugin-discovered camera stream metadata as device enrichment tied to canonical device identity.

#### Scenario: Stream metadata attached to canonical device
- **GIVEN** a plugin result containing a valid `device_enrichment.streams` payload and identity hints
- **WHEN** ingestion resolves the canonical device
- **THEN** the stream metadata SHALL be stored as enrichment for that device
- **AND** previous stream observations from the same source SHALL be updated atomically

### Requirement: Stream authentication metadata without secret leakage
The system SHALL store stream authentication requirements and credential reference IDs without storing plaintext secrets in device inventory or enrichment rows.

#### Scenario: Credential reference stored safely
- **GIVEN** a discovered RTSP stream requiring authentication
- **WHEN** enrichment is persisted
- **THEN** the record SHALL include auth mode and credential reference ID only
- **AND** SHALL NOT include raw usernames or passwords in persisted enrichment payloads

### Requirement: Device UI exposure for discovered streams
The device details experience SHALL expose discovered stream metadata (protocol, endpoint, profile, auth mode, freshness) sourced from enrichment records.

#### Scenario: Device details shows discovered AXIS stream entries
- **GIVEN** a device with current stream enrichment data
- **WHEN** a user opens the device details view
- **THEN** the UI SHALL show stream entries and freshness timestamps
- **AND** it SHALL indicate when credentials are required but not configured
