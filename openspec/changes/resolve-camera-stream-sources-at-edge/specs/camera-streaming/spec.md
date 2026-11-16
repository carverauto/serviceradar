## ADDED Requirements

### Requirement: Stream address reduction at Core entry
Core SHALL apply one stream address reduction to every plugin result before persisting it or passing it to any handler, on the durable edge-record path and on the legacy status path. The reduction SHALL replace every `rtsp://` and `rtsps://` URL with its origin (scheme, host, port), SHALL remove userinfo from every other URL, and SHALL remove keys named `rtsp_alias`, `rtsps_alias`, `rtspAlias` or `rtspsAlias` in any letter case, including inside JSON-encoded string fields.

#### Scenario: Un-upgraded plugin reports an alias URL
- **WHEN** a plugin result contains `rtsps://192.0.2.10:7441/AbCdEf` and a profile metadata key `rtsps_alias`
- **THEN** every stored copy and every handler input holds only `rtsps://192.0.2.10:7441`
- **AND** no stored row contains the `rtsps_alias` key

#### Scenario: Credentials in a generic stream URL
- **WHEN** a plugin result contains `rtsp://viewer:secret@cam01.example.com/live`
- **THEN** Core stores `rtsp://cam01.example.com` and never stores `viewer` or `secret`

### Requirement: Camera inventory holds no stream secret
Camera inventory SHALL store only non-secret stream facts: the profile `source_origin`, the profile name, transport, codec and container hints, the vendor camera and profile ids, and the source `discovery_assignment_id`. A stream address, path alias or stream credential SHALL NOT be readable through Ash reads, SRQL, APIs, LiveView assigns, AshAdmin, logs or events.

#### Scenario: Viewer with camera permission loads a device page
- **WHEN** a user with camera-view permission opens a camera device page
- **THEN** the page offers the TLS-bypass control from `source_scheme` alone
- **AND** no socket assign contains a stream path, alias or credential

#### Scenario: Device metadata through SRQL
- **WHEN** a user runs `in:devices` for a camera device
- **THEN** the returned metadata contains no `camera_source_url` and no stream path

### Requirement: Stream sources resolve at the edge at open time
When opening a camera relay, Core SHALL send the discovering plugin assignment id and the vendor camera and profile ids, and SHALL NOT send a stream address. The agent SHALL obtain the address from that assignment's plugin resolver when the stream opens as a single URL, which is the only channel for the address and any stream credential and may carry userinfo. The agent SHALL hold that URL only in memory for the session, SHALL pass it to the native reader, and SHALL NOT persist it, log it, return it in a command result or include it in an error. Core SHALL NOT dispatch to an agent that lacks the `camera_source_resolution` capability.

#### Scenario: Upgraded agent opens a Protect stream
- **WHEN** an operator opens a Protect camera profile on an agent advertising `camera_source_resolution`
- **THEN** the `camera.open_relay` payload carries `source_resolver` and no `source_url`
- **AND** the agent resolves the address through the assignment and streams it with the native reader

#### Scenario: Agent not upgraded
- **WHEN** the assigned agent does not advertise `camera_source_resolution`
- **THEN** Core does not dispatch the command
- **AND** the relay session fails with reason `agent_upgrade_required`, shown to the operator as a sentence

#### Scenario: Resolution fails
- **WHEN** the resolver assignment is not loaded, the plugin returns no resolution document, or the controller does not know the camera or profile
- **THEN** the session fails with `source_resolver_unavailable`, `source_resolver_unsupported` or `source_not_found` respectively
- **AND** the failure detail contains no address or credential

### Requirement: Existing stream secrets are removed
The system SHALL remove every stored stream address, path alias and URL userinfo from camera inventory, device metadata and plugin status rows by an Oban job that a migration enqueues. The job SHALL repeat passes until a pass that started after every connected Core node runs the reduction finds nothing to change.

#### Scenario: Rolling upgrade
- **WHEN** an old Core replica writes a copy after the job's first pass
- **THEN** a later pass removes it
- **AND** the job does not finish until a pass that started after the last old node left the cluster changes nothing

#### Scenario: Operator verification
- **WHEN** the job reports completion
- **THEN** each operator verification query defined in design D7 returns 0
