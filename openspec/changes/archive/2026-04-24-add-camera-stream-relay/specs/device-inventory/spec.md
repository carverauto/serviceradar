## ADDED Requirements
### Requirement: Camera stream inventory uses normalized platform tables
The system SHALL store camera source identifiers and stream profile metadata in dedicated `platform` schema tables linked to canonical device identity rather than relying only on opaque metadata fields in `ocsf_devices`.

#### Scenario: Protect plugin discovers a camera and stream profiles
- **GIVEN** camera discovery identifies a canonical device and one or more vendor stream profiles
- **WHEN** the discovery payload is ingested
- **THEN** the canonical device SHALL remain represented in `ocsf_devices`
- **AND** camera-specific source and stream profile records SHALL be created or updated in dedicated related tables

### Requirement: Camera inventory tracks edge affinity and freshness
The camera inventory model SHALL track which edge agent or gateway can originate a camera stream session and SHALL retain freshness metadata for discovered camera profiles.

#### Scenario: Camera profile becomes stale
- **GIVEN** a camera stream profile was last observed by discovery at an earlier timestamp
- **WHEN** that profile is no longer refreshed within the configured freshness window
- **THEN** the system SHALL mark the profile stale
- **AND** viewer workflows SHALL be able to surface that state before attempting live playback
