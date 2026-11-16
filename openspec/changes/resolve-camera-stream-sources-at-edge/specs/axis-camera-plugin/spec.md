## MODIFIED Requirements

### Requirement: Stream discovery and normalization
The AXIS plugin SHALL discover camera streams from VAPIX APIs and emit normalized stream metadata including protocol and authentication requirements. When its assignment config carries the inventory address cutover key defined in design D8, a stream entry SHALL carry the stream origin (scheme, host, port) and no stream URL path or userinfo. Without that key the plugin SHALL report stream entries as it did before this change, including the media path.

#### Scenario: RTSP profiles discovered
- **GIVEN** an AXIS camera exposing stream profiles
- **WHEN** the plugin executes stream discovery
- **THEN** the result SHALL include one or more stream entries with profile identifiers, endpoint metadata, and auth mode

#### Scenario: Core has not cut over
- **GIVEN** no design D8 key in the assignment config
- **WHEN** the plugin reports a stream for camera `192.0.2.20`
- **THEN** the stream entry SHALL carry `rtsp://192.0.2.20/axis-media/media.amp` with its query parameters, as before this change

#### Scenario: Core has cut over
- **GIVEN** the design D8 key in the assignment config
- **WHEN** the plugin reports a stream for camera `192.0.2.20`
- **THEN** the stream entry SHALL carry the origin `rtsp://192.0.2.20` and no media path

## ADDED Requirements

### Requirement: Axis stream source resolution
The AXIS plugin SHALL resolve one camera profile's stream address on request by rebuilding the VAPIX media URL from the assignment's camera host and the requested profile. The address carries no secret. The plugin SHALL take stream credentials from its plugin config and MAY place them as userinfo on the resolved URL, which exists only in the resolution response and in agent memory, as design D4 states; it SHALL NOT put them in any inventory result.

#### Scenario: Resolution with plugin credentials
- **WHEN** the agent requests resolution for camera `192.0.2.20` and an existing profile
- **THEN** the plugin returns `rtsp://<user>:<password>@192.0.2.20/axis-media/media.amp?<params>` only in the resolution response, with the user and password taken from its plugin config

#### Scenario: Unknown profile
- **WHEN** the requested profile does not exist on the camera
- **THEN** the plugin returns failure class `source_not_found`
