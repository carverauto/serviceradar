## ADDED Requirements

### Requirement: Dashboards can play camera streams
The dashboard platform SHALL let a dashboard package that declares the `camera.stream.view` capability open, attach, observe and close camera relay viewer sessions through a host camera API, and the SDK SHALL expose that API as `useCameraStream`, `<CameraTile>` and `<CameraGrid>` with TypeScript types.
The host SHALL authorize each session with the viewing user's camera permissions, SHALL reuse the web-ng relay player's signaling, retry and fallback logic, and SHALL close every session a renderer opened when the renderer is destroyed.

#### Scenario: Package without the capability
- **WHEN** a dashboard package that does not declare `camera.stream.view` calls the camera API
- **THEN** the host SHALL reject the call and open no relay session

#### Scenario: User without camera permission
- **WHEN** a user lacking camera view permission loads a dashboard that declares `camera.stream.view`
- **THEN** camera tiles SHALL show an unauthorized state and no relay session SHALL be opened

#### Scenario: Several streams at once
- **WHEN** a dashboard opens four camera tiles for four different camera sources
- **THEN** all four SHALL play concurrently
- **AND** each SHALL report its own state through `onState`

#### Scenario: Renderer destroyed
- **WHEN** the user navigates away from a dashboard with open camera tiles
- **THEN** the host SHALL close every relay viewer session that dashboard opened

#### Scenario: Validated against real cameras
- **WHEN** the camera API is first released
- **THEN** a dashboard SHALL have played at least two UniFi Protect camera streams concurrently in the `demo` namespace through it

### Requirement: Camera tiles draw analysis detections
The host camera API SHALL expose analysis detections for an open session through an `onDetections` subscription, and `<CameraTile>` SHALL draw them as labelled boxes aligned to the video frame they belong to.

#### Scenario: Detection overlay
- **WHEN** detections arrive for a playing camera tile
- **THEN** the tile SHALL draw each box with its label and confidence over the matching frame
- **AND** SHALL remove boxes once their frame is no longer displayed

### Requirement: Camera sessions per dashboard are bounded
The host SHALL cap the number of concurrent camera sessions a single dashboard renderer may hold (default nine) and SHALL reject further opens with a distinguishable error.

#### Scenario: Tile limit exceeded
- **WHEN** a renderer already holding the maximum number of sessions opens another
- **THEN** the host SHALL reject the open with a session-limit error
- **AND** existing sessions SHALL keep playing

### Requirement: Camera sources are discoverable through SRQL
SRQL SHALL expose camera sources and their stream profiles as an entity that dashboard frames can query, so a dashboard can list cameras without a camera-specific host call.

#### Scenario: Dashboard lists cameras
- **WHEN** a dashboard frame queries the camera-source entity
- **THEN** the frame SHALL include each source's id, display name, owning device, availability and stream profile ids the user may view

### Requirement: Dev harness supports offline camera tiles
The dashboard dev harness SHALL provide a mock camera API so camera tiles render a placeholder or local test stream without a live ServiceRadar.

#### Scenario: Harness without network
- **WHEN** a dashboard with camera tiles runs in the dev harness with no ServiceRadar reachable
- **THEN** each tile SHALL render the mock stream and report a playing state

### Requirement: Frame refresh interval is configurable
A dashboard manifest SHALL be able to set a refresh interval per data frame, which the host SHALL clamp to the one-to-sixty-second range and use instead of a fixed interval.

#### Scenario: Fast frame
- **WHEN** a manifest declares `refresh_interval_ms: 2000` for a frame
- **THEN** the host SHALL refresh that frame about every two seconds

#### Scenario: Out-of-range interval
- **WHEN** a manifest declares a refresh interval below one second
- **THEN** the host SHALL use one second

### Requirement: Non-geographic plan views
The SDK SHALL provide a deck.gl canvas helper for non-geographic (orthographic) plan views that accepts the same layer factories, popup helpers and theme handling as the map helpers and requires no basemap token.

#### Scenario: Plan view without Mapbox
- **WHEN** a dashboard renders a plan view with no Mapbox token configured
- **THEN** the plan view SHALL render its layers and popups

### Requirement: Dev harness resolves fixtures for SRQL updates
The dashboard dev harness SHALL pass SRQL query updates to an optional author-supplied fixture resolver and SHALL deliver the frames it returns, and SHALL be able to serve its map libraries locally without internet access.

#### Scenario: Filter chip offline
- **WHEN** a dashboard in the dev harness applies a filter and its config supplies a fixture resolver
- **THEN** the harness SHALL deliver the resolver's frames to the dashboard

### Requirement: Dashboards can invoke plugin actions
The dashboard platform SHALL let a dashboard package that declares the `actions.invoke` capability list the plugin actions available for its targets and invoke them through the northbound action model, with the host enforcing the user's action permissions, recording audit and invocation history, and reporting the invocation's progress and result to the dashboard.

#### Scenario: Permitted invocation
- **WHEN** a permitted user triggers a plugin action from a dashboard declaring `actions.invoke`
- **THEN** the host SHALL submit the invocation through the northbound action model
- **AND** SHALL report its progress and final result to the dashboard
- **AND** the invocation SHALL appear in action history with the user as actor

#### Scenario: Permission denied
- **WHEN** a user without permission for an action tries to invoke it from a dashboard
- **THEN** the host SHALL reject the invocation without contacting the agent

#### Scenario: Package without the capability
- **WHEN** a dashboard package that does not declare `actions.invoke` calls the action API
- **THEN** the host SHALL reject the call

### Requirement: Dashboards receive live events
The dashboard platform SHALL let a dashboard subscribe to OCSF events matching a filter, scoped to what the user may see, and SHALL let a dashboard request an immediate refresh of its frames, so dashboards change state within seconds of an event instead of waiting for the next frame refresh.

#### Scenario: Matching event arrives
- **GIVEN** a dashboard subscribed to events from its plugin's source
- **WHEN** a matching OCSF event is persisted
- **THEN** the dashboard SHALL receive it within seconds
- **AND** a frame refresh requested in response SHALL return data that includes the event's effects

#### Scenario: Event outside the user's scope
- **WHEN** an event the user may not see matches a subscription filter
- **THEN** the host SHALL NOT deliver it

#### Scenario: Offline harness
- **WHEN** a dashboard with an event subscription runs in the dev harness
- **THEN** the harness SHALL deliver events from the selected fixture on a timeline

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
