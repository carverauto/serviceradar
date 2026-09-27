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
