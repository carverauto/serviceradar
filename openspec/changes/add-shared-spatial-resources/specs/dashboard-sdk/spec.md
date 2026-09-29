## ADDED Requirements

### Requirement: Shared spatial locations preserve coordinate identity
The dashboard host and SDK SHALL exchange versioned spatial locations containing a resource id, coordinate-space id, coordinate version and camera, with explicit geographic or Cartesian semantics. Dashboard links SHALL identify the dashboard instance and stable map-view id and SHALL support arbitrary fixed or moving objects through provider-owned stable identities. The host SHALL resolve resource ids through authorized providers and SHALL own application navigation and share URLs.

#### Scenario: Geographic and plan coordinates remain distinct
- **WHEN** a drone map and an indoor plan use the spatial interfaces
- **THEN** the geographic adapter SHALL interpret longitude/latitude and the plan adapter SHALL interpret its declared plan units and axis direction
- **AND** a location from one resource or coordinate space SHALL NOT be applied to the other

#### Scenario: A shared location outlives telemetry updates
- **WHEN** an authorized user opens a location whose coordinate version remains available
- **THEN** the view SHALL restore its center and scale with current authorized data
- **AND** telemetry updates and process restarts SHALL NOT change the meaning of that location

#### Scenario: A coordinate version is unavailable
- **WHEN** a link refers to a replaced coordinate version
- **THEN** the host SHALL explain that the saved layout is unavailable and offer the current Home view
- **AND** SHALL NOT silently reinterpret the saved coordinates under the new layout

#### Scenario: Sharing does not grant access
- **WHEN** a recipient lacks permission for the resource in a shared link
- **THEN** ordinary resource authorization SHALL deny its data
- **AND** the URL SHALL contain no backend URL, credential or authorization grant

#### Scenario: A dashboard contains multiple maps
- **WHEN** a recipient opens a shared location for one map on a dashboard
- **THEN** the host SHALL open the identified dashboard instance and restore the identified map view after its authorized resource is ready
- **AND** saved preferences, initial fit-to-bounds and later frame refreshes SHALL NOT overwrite that restored camera

#### Scenario: Share a fixed view containing a moving object
- **WHEN** an operator shares a view with a selected object and the object moves before the recipient opens it
- **THEN** the map SHALL retain the shared area and scale, with current authorized data
- **AND** selection SHALL use stable identity without moving the camera to the object's newer position
- **AND** a missing selection SHALL leave the valid shared area visible with an explicit unavailable message

#### Scenario: Share an object's current location
- **WHEN** an operator chooses an object link rather than a fixed-view link
- **THEN** the provider SHALL resolve that stable identity and the view SHALL center its current position when opened
- **AND** the shared interface SHALL require no drone, device, SNMP or other domain-specific object class
- **AND** continuous tracking SHALL require a separate explicit user action

#### Scenario: The address bar tracks the visible camera
- **WHEN** a user pans or zooms a map
- **THEN** the host SHALL update readable coordinate and zoom query parameters after a bounded debounce, preserving unrelated dashboard query state
- **AND** geographic views SHALL expose latitude/longitude, while Cartesian views SHALL expose X/Y with their coordinate-space identity
- **AND** camera motion SHALL replace the current history entry rather than add an entry per movement
- **AND** reopening the URL SHALL restore that camera; visible tile coverage SHALL be derived for the recipient's viewport dimensions

### Requirement: Tiled spatial sources compose with existing dashboard views
The platform SHALL expose bounded spatial tile sources independently of topology-specific decoding, layout and telemetry, and the SDK SHALL compose these sources with its existing geographic and plan-view helpers and layer factories. Bounded frame-based views SHALL continue working without tiles.

#### Scenario: A second resource reuses navigation and transport
- **WHEN** a non-network plan resource uses the tiled source interface
- **THEN** it SHALL reuse cancellation, cache budgeting, revision handling and location navigation without Dgraph, SNMP or ELK dependencies
- **AND** its payload adapter SHALL supply its own layers and stable selection identities

#### Scenario: Resource changes while data is in flight
- **WHEN** a dashboard switches spatial resource or unmounts
- **THEN** pending reads and subscriptions SHALL be disposed and late results SHALL NOT populate the new view
- **AND** cache keys SHALL distinguish resource, coordinate space/version, tile address and payload format

#### Scenario: Telemetry changes on an unchanged tile
- **WHEN** a supported overlay changes without a geometry change
- **THEN** the source SHALL update the overlay without downloading geometry again
