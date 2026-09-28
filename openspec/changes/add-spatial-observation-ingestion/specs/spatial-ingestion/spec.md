## ADDED Requirements

### Requirement: Typed spatial observations
The platform SHALL accept bounded, versioned atomic spatial observations through
the authorized plugin telemetry path, with equivalent Go and Rust SDK builders,
and SHALL retain stable object identity, coordinate-space identity/version,
event time, producer provenance and position quality without plugin-selected stores.

#### Scenario: Atomic geographic observation
- **WHEN** a plugin emits one accepted longitude/latitude observation
- **THEN** both coordinates SHALL share one identity and event timestamp
- **AND** the host SHALL reject an unsupported version, invalid coordinates or unauthorized resource
- **AND** the plugin SHALL not supply a database credential, table or query to route it

#### Scenario: Cartesian and geographic objects coexist
- **WHEN** two authorized resources use different coordinate spaces
- **THEN** each SHALL retain its units, axes and version
- **AND** the platform SHALL not treat a Cartesian position as geographic latitude/longitude
