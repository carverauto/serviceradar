## ADDED Requirements

### Requirement: Operator-selected audit sources
Core SHALL publish audit change events on `audit.changes.v1.<source_id>` for every enabled source, where the sources are the recording custody sources (`recording.holds`, `recording.policies`, `recording.archive_settings`, `recording.storage_settings`, `recording.dispositions`, `recording.camera_availability`, `recording.access`), any PaperTrail resource listed in `auditEvents.sources.paperTrail`, and any AshEvents resource listed in `auditEvents.sources.ashEvents`. Recording custody sources MUST be enabled by default whenever recording is enabled. Core MUST reconcile the enabled set from Helm values into `platform.audit_event_sources` at boot.

#### Scenario: Default recording install
- **WHEN** core starts with recording enabled and default values
- **THEN** all `recording.*` sources are enabled and no PaperTrail or AshEvents source is enabled

#### Scenario: Operator adds a PaperTrail source
- **WHEN** an operator adds `ServiceRadar.Notifications.NotificationRoute` to `auditEvents.sources.paperTrail` and upgrades
- **THEN** every new version row for that resource produces one message on `audit.changes.v1.paper_trail:ServiceRadar.Notifications.NotificationRoute`

#### Scenario: Unknown resource configured
- **WHEN** Helm lists a resource that has no PaperTrail version table
- **THEN** core logs it, reports it in `unknown_configured_sources` of the capture status, and continues booting

### Requirement: Base-table capture for recording custody
Recording custody sources SHALL be captured by triggers on their base tables, so that writes bypassing the Ash actions are published. Each message MUST carry the actor ID when known, the change source (`action`, `configuration`, `retention`, `system`, or `out_of_band` when no context is set), the transaction timestamp, the source record ID, and `before`/`after` projections of custody-relevant fields.

#### Scenario: Retention override reduced through the UI
- **WHEN** a user changes a policy's archive retention override from 30 to 10 days
- **THEN** a message carries the user's actor ID, `change_source` `action`, `before.archive_retention_days_override` 30 and `after.archive_retention_days_override` 10

#### Scenario: Hold updated by SQL
- **WHEN** a hold row is updated by SQL outside the Ash actions
- **THEN** a message is published with `actor_id` null and `change_source` `out_of_band`

### Requirement: Audit scope changes are always announced
Every change to `platform.audit_event_sources` SHALL publish an `audit.scope.v1` message with the source ID, before and after enabled state, change source and actor, and this capture MUST NOT itself be controllable through the source registry.

#### Scenario: Source disabled by Helm
- **WHEN** an operator removes `recordingCustody` from Helm values and core restarts
- **THEN** `audit.scope.v1` messages record each `recording.*` source changing from enabled to disabled with `change_source` `configuration`

### Requirement: Audit row deletion visibility
Retention-driven purges of PaperTrail versions and AshEvents rows SHALL publish one `audit.retention_purged` summary per source and run (count, cutoff, actor) instead of per-row events, and any other delete of an audit row from an enabled source MUST publish a delete event with the removed row's identifiers and change source.

#### Scenario: Version row deleted out of band
- **WHEN** a version row of an enabled PaperTrail source is deleted by SQL
- **THEN** a delete event with `change_source` `out_of_band` is published

#### Scenario: Scheduled retention purge
- **WHEN** the retention worker purges 5,000 version rows of one source
- **THEN** exactly one `audit.retention_purged` message is published for that source and run

### Requirement: Sensitive attribute redaction and size bounds
Audit messages SHALL replace values of attributes listed in a resource's PaperTrail `ignore_attributes` or marked `sensitive?` with `"[redacted]"` while keeping the attribute name, MUST NOT contain credentials, bucket names, endpoints, object keys or media, and MUST NOT exceed 32 KiB; larger changes MUST be replaced by `changes_sha256` with `truncated: true`.

#### Scenario: Credential secret changed
- **WHEN** a `NetworkCredentialSecret` source is enabled and its secret payload changes
- **THEN** the message names the changed attribute with value `"[redacted]"`

### Requirement: Trigger outbox and acknowledged relay
Events SHALL be written to outbox tables by triggers in the writing transaction, and a single coordinator relay SHALL publish them in outbox order with `Nats-Msg-Id` `<outbox>:<id>`, deleting a row only after acknowledgment. The relay MUST report outbox depth and oldest-row age and raise a health event when the oldest row is older than 10 minutes.

#### Scenario: Rollback
- **WHEN** a transaction that updated an audited table rolls back
- **THEN** no audit message is published for it

#### Scenario: NATS unavailable
- **WHEN** NATS is unreachable for 30 minutes
- **THEN** outbox rows accumulate, a health event is raised, and every row is published once NATS returns

### Requirement: Capture status heartbeat
Core SHALL publish `audit.capture.v1.status` every 60 seconds listing each configured source with its enabled state, trigger state from `pg_trigger` (`enabled`, `disabled`, `missing`), and last event ID, plus outbox depth, oldest-row age, and unknown configured sources.

#### Scenario: Trigger disabled by a superuser
- **WHEN** a database superuser disables the trigger on `camera_recording_policies`
- **THEN** the next capture status reports `recording.policies` with `trigger_state` `disabled`

### Requirement: Core-owned audit change stream
Core SHALL create and reconcile `AUDIT_CHANGE_EVENTS` (subjects `audit.changes.v1.>`, `audit.scope.v1`, `audit.capture.v1.status`; file storage; 7-day default `max_age`; finite `max_bytes`; metadata `serviceradar.owner` `core-elx`) when audit events are enabled, and the render-time JetStream budget MUST count it.

#### Scenario: Fresh install
- **WHEN** core starts with audit events enabled and the stream is absent
- **THEN** core creates it with a positive `max_bytes` and the owner metadata

### Requirement: Integrity forwarder NATS identity
The chart SHALL define a static NATS user `CN=serviceradar-integrity-forwarder` allowed to create, read and acknowledge consumers on `CAMERA_RECORDING_EVENTS` and `AUDIT_CHANGE_EVENTS`, subscribe to `integrity.rpc.evidence.>`, and publish `_INBOX.>`, with no other core-subject grants, and core SHALL be allowed to publish `camera.recording.>` and `audit.>`.

#### Scenario: Permission rendering
- **WHEN** the chart is rendered with the integrity forwarder enabled
- **THEN** the static user permissions test confirms the forwarder's consumer grants on both streams and the absence of other core-subject grants
