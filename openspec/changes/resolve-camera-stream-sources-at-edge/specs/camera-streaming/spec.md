## ADDED Requirements

### Requirement: Stream address reduction at Core entry
Core SHALL apply one stream address reduction to every plugin result before persisting it or passing it to any handler, on the durable edge-record path and on the legacy status path. The reduction SHALL replace every `rtsp://` and `rtsps://` URL with its origin (scheme, host, port), SHALL remove userinfo from every other URL, and SHALL remove keys named `rtsp_alias`, `rtsps_alias`, `rtspAlias` or `rtspsAlias` in any letter case. It SHALL apply these rules inside strings that are themselves JSON, to a bounded nesting depth beyond which the value is replaced by a marker, and to URLs written with JSON solidus escapes, as defined once in design D2. While Core still writes `camera_sources.source_url` and `camera_stream_profiles.source_url_override` (before Stage 3), the values written to those two columns SHALL come only from the relay address extract of the design D2 Stage 1 ingest rule, and that extract SHALL NOT be persisted, logged or passed anywhere else.

#### Scenario: Scheduled report after a zero scrub pass
- **GIVEN** Core before Stage 3, and a scrub pass after which `pending/0` reports zero for every in-scope target
- **WHEN** the next scheduled plugin report arrives carrying `rtsps://192.0.2.10:7441/AbCdEf` for a camera profile
- **THEN** `pending/0` still reports zero for every in-scope target
- **AND** `source_url_override` for that profile holds `rtsps://192.0.2.10:7441/AbCdEf`

#### Scenario: Un-upgraded plugin reports an alias URL
- **WHEN** a plugin result contains `rtsps://192.0.2.10:7441/AbCdEf` and a profile metadata key `rtsps_alias`
- **THEN** every handler input and every stored copy holds only `rtsps://192.0.2.10:7441`, except the two relay columns before Stage 3
- **AND** no stored row contains the `rtsps_alias` key

#### Scenario: Credentials in a generic stream URL
- **WHEN** a plugin result contains `rtsp://viewer:secret@cam01.example.com/live`
- **THEN** every copy Core stores outside the two relay columns is `rtsp://cam01.example.com`
- **AND** from Stage 3 Core stores neither `viewer` nor `secret` anywhere

### Requirement: Core owns the inventory address cutover
Core SHALL deliver the host-owned assignment config key defined in design D8 to camera inventory plugin assignments starting with the release that stops writing `source_url` and `source_url_override` (Stage 3), and SHALL NOT deliver it before. A camera inventory plugin that implements stream source resolution SHALL omit stream addresses and alias keys from its inventory results when that key is present, and SHALL report them unchanged when it is absent.

#### Scenario: New plugin and Core before cutover
- **GIVEN** a plugin with a stream source resolver and Core before Stage 3, with `source_url_override` holding `rtsps://192.0.2.10:7441/AbCdEf`
- **WHEN** the plugin sends an inventory report for that camera
- **THEN** the report carries `rtsps://192.0.2.10:7441/AbCdEf` as before
- **AND** after the inventory upsert `source_url_override` still holds `rtsps://192.0.2.10:7441/AbCdEf` and a relay opened by Core uses it

#### Scenario: New plugin and Core after cutover
- **WHEN** the plugin runs with the design D8 key in its assignment config
- **THEN** its inventory report carries the origin `rtsps://192.0.2.10:7441` and no stream address, `streams[].url` or alias key

#### Scenario: Old plugin and Core after cutover
- **WHEN** a plugin without resolver support reports `rtsps://192.0.2.10:7441/AbCdEf` to Core from Stage 3
- **THEN** Core reduces it to `rtsps://192.0.2.10:7441` at entry
- **AND** no camera inventory row, device metadata or plugin status row holds the path

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
The system SHALL remove every stored stream address, path alias and URL userinfo from camera inventory, device metadata and plugin status rows by an Oban job that a migration enqueues. Each job SHALL name the stage it must complete, and SHALL complete only on a pass run by code at or above that stage, with every connected Core node at or above that stage, that scrubbed every target of that stage and changed nothing, as defined in design D7. Until then the job SHALL be snoozed and continued as the same job, never by inserting a follow-up job, as defined in design D7.

#### Scenario: Rolling upgrade
- **WHEN** an old Core replica writes a copy after the job's first pass
- **THEN** a later pass removes it
- **AND** the job does not complete while any connected Core node reports a scrub stage below the job's stage

#### Scenario: Stage 3 job picked up by a Stage 1 node
- **WHEN** a Core node running Stage 1 code picks up the scrub job enqueued with stage 3
- **THEN** the node snoozes the job and does not complete it
- **AND** the job completes later only on a pass by Stage 3 or later code under the D7 rule

#### Scenario: Operator verification
- **WHEN** the job reports completion
- **THEN** the scrub worker's `pending/0` check defined in design D7 returns zero for every target in scope for the running stage
- **AND** while the Stage 3 targets are not yet in scope, `pending/0` separately reports the rows still holding an address in `source_url` and `source_url_override` by column name
