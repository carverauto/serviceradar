## MODIFIED Requirements

### Requirement: Protect camera inventory and stream discovery
The UniFi Protect plugin SHALL interrogate Protect controller APIs and report normalized camera inventory metadata and stream descriptors that contain no stream secret. A stream descriptor SHALL carry the profile name, the vendor profile id (quality or channel id), transport and codec hints, and the stream origin (scheme, host, port). It SHALL NOT carry an RTSP or RTSPS path, an `rtspAlias` or `rtspsAlias` value, or raw controller channel objects.

#### Scenario: Protect camera metadata retrieved successfully
- **GIVEN** valid Protect controller credentials and reachable controller APIs
- **WHEN** the plugin runs
- **THEN** it SHALL collect camera identity metadata and stream descriptor information
- **AND** include normalized values in plugin result details and enrichment payloads
- **AND** no part of the result SHALL contain a stream alias or a stream URL path

## ADDED Requirements

### Requirement: Protect stream source resolution
The UniFi Protect plugin SHALL resolve one camera profile's stream address on request, from the controller, using the assignment's own controller host and credential. It SHALL use the integration `rtsps-stream` API first and the bootstrap channel alias second. It SHALL NOT create, enable or rotate a stream on the controller.

#### Scenario: Integration API resolution
- **WHEN** the agent requests resolution for camera `cam-01` and quality `high`
- **THEN** the plugin reads that camera's `rtsps-stream` document, removes `enableSrtp`, and returns the address only in the resolution response

#### Scenario: RTSP disabled for the requested quality
- **WHEN** the controller reports no stream for the requested quality
- **THEN** the plugin returns failure class `source_not_found`
- **AND** it does not create a stream
