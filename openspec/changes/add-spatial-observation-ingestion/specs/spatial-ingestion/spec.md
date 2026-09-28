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

### Requirement: Durable history and bounded current positions
Spatial observations SHALL traverse JetStream before persistence, with EventWriter
writing history to exactly the configured telemetry backend and a replayable,
bounded current-position projection exposing source identity and freshness.

#### Scenario: Warehouse outage
- **WHEN** StarRocks is enabled but cannot accept observations
- **THEN** history delivery SHALL remain retryable within configured stream retention
- **AND** no CNPG telemetry fallback or duplicate history write SHALL occur
- **AND** readers SHALL expose unavailable or delayed data rather than a frozen fallback

#### Scenario: Out-of-order replay
- **WHEN** an older accepted position is delivered after a newer one or a record is redelivered
- **THEN** history SHALL remain idempotent
- **AND** current state SHALL not move backward or emit duplicate movement effects
- **AND** stale or conflicting producer state SHALL be identifiable

### Requirement: Store-independent spatial reads
Authorized map providers SHALL expose bounded geometry, dynamic position overlays,
identity lookup and time-bounded history without requiring dashboards to query
CNPG, StarRocks or Dgraph directly.

#### Scenario: Moving object in a shared resource
- **WHEN** a moving object changes position while a dashboard is open
- **THEN** the overlay SHALL update without refetching unchanged static geometry
- **AND** current-position lag SHALL be visible
- **AND** the same provider contract SHALL support a fixed non-device object

#### Scenario: Relationship projection
- **WHEN** an accepted relationship changes between known objects
- **THEN** the canonical relation path SHALL update its Dgraph projection idempotently
- **AND** subsequent position samples SHALL not create redundant graph relationships
