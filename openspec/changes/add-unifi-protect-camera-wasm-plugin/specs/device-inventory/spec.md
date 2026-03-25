## ADDED Requirements
### Requirement: Protect plugin-discovered camera enrichment
The system SHALL persist UniFi Protect plugin-discovered camera and stream metadata as device enrichment tied to canonical device identity.

#### Scenario: Protect stream metadata attached to canonical device
- **GIVEN** a plugin result containing valid Protect `camera_descriptors` payloads and identity hints
- **WHEN** ingestion resolves the canonical device
- **THEN** the Protect camera and stream metadata SHALL be stored as enrichment for that device
- **AND** previous observations from the same plugin source SHALL be updated atomically

### Requirement: Protect metadata exposed in device views
The device details experience SHALL expose UniFi Protect-discovered camera stream metadata sourced from enrichment records.

#### Scenario: Device details shows discovered Protect stream entries
- **GIVEN** a device with current Protect camera enrichment data
- **WHEN** a user opens the device details view
- **THEN** the UI SHALL show stream entries and freshness timestamps
- **AND** it SHALL indicate when controller-managed credentials or session bootstrap are required
