## ADDED Requirements

### Requirement: DJI hardware is inventoried by serial, not address
The platform SHALL represent every DJI gateway, aircraft, payload, relay and dock sub-device as a `Device` identified by a scoped integration identifier derived from its DJI serial number. IP addresses and SIM identifiers SHALL be recorded only as attributes.

#### Scenario: Aircraft moves between gateways
- **WHEN** an aircraft first reported by one dock is later reported by a different dock or controller
- **THEN** it SHALL resolve to the same device
- **AND** its current gateway relationship SHALL be updated

#### Scenario: Gateway without a stable IP
- **WHEN** a dock connects over a cellular network with a changing source address
- **THEN** no device SHALL be created or merged on the basis of that address

### Requirement: DJI current state is held in a sibling resource
The platform SHALL keep the current state of each DJI device in a resource keyed by `device_uid`. That state SHALL include kind, domain, model key, model name, gateway, firmware, binding state, online state, mode and reported live-stream capability. History SHALL live only in telemetry.

#### Scenario: Model key resolution
- **WHEN** a topology report lists a sub-device with domain, type and subtype
- **THEN** the platform SHALL record its `domain-type-subtype` model key and the model name from DJI's published product table

### Requirement: Topology reports are complete per gateway
The platform SHALL treat each gateway topology report as the complete set of that gateway's sub-devices. A sub-device absent from the latest report SHALL be marked offline for that gateway and SHALL NOT be deleted.

#### Scenario: Aircraft leaves the topology
- **WHEN** a dock reports a topology with an empty sub-device list
- **THEN** its aircraft SHALL be marked offline
- **AND** the aircraft device and its history SHALL remain

### Requirement: Drone telemetry flows through JetStream
The platform SHALL convert DJI OSD and state properties into metric records and spatial observations published to JetStream and persisted by EventWriter. Per-device forwarding MUST be capped at the configured rate and MUST NOT exceed 1 Hz.

#### Scenario: Battery and environment metrics
- **WHEN** a dock reports OSD with environment, battery and network fields
- **THEN** the corresponding metrics SHALL be queryable through the telemetry store selected by the installation, attributed to the reporting device

#### Scenario: Position reporting
- **WHEN** an aircraft reports latitude, longitude, height and heading
- **THEN** the platform SHALL emit a spatial observation for the aircraft's identity
- **AND** SHALL update its current position for map display

### Requirement: HMS alarm sets become OCSF raise and clear events
The platform SHALL diff each DJI HMS report against the previous alarm set for the same device. It SHALL emit an OCSF raise event for each new alarm and a clear event for each alarm that is no longer present, with human-readable text from DJI's HMS catalog.

#### Scenario: Alarm clears
- **WHEN** an HMS code present in the previous report is absent from the next report for the same device and component
- **THEN** the platform SHALL emit a clear event for that alarm

#### Scenario: Catalog unavailable
- **WHEN** the HMS text catalog cannot be refreshed
- **THEN** the platform SHALL use its vendored catalog snapshot
- **AND** SHALL still emit the event with the raw code

### Requirement: DJI cameras are camera sources
The platform SHALL register each DJI payload and dock camera as a camera source owned by its aircraft or dock device, with one stream profile per reported video type. Viewing, recording, semantic search and video analytics SHALL then apply through the existing camera source scope.

#### Scenario: Live capability creates stream profiles
- **WHEN** a gateway reports `live_capacity` listing a camera with `normal`, `zoom` and `ir` video types
- **THEN** the camera source SHALL expose three stream profiles
- **AND** no stream address SHALL be stored

### Requirement: Drone fleet query and UI surfaces
The platform SHALL provide an `in:drones` SRQL entity over current fleet state, a drone tab on DJI device detail pages, and a first-party drone fleet dashboard package. The dashboard SHALL show a geographic fleet map, a fleet table, dock environment, an HMS feed and live camera tiles.

#### Scenario: Query low-battery aircraft
- **WHEN** a user runs an `in:drones` query filtered to aircraft with battery below a threshold
- **THEN** only aircraft the user is authorized to view SHALL be returned with their current battery and gateway

#### Scenario: Dashboard live tile
- **WHEN** a user with camera view permission opens a drone tile in the fleet dashboard
- **THEN** the dashboard SHALL open a live stream for that camera source through the host camera API
