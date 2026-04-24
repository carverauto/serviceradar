## ADDED Requirements

### Requirement: Event-derived alerts SHALL be incident-grouped
The system SHALL treat repeated event-derived alerts as incident updates when incoming events resolve to the same incident fingerprint and the existing incident is still active.

#### Scenario: Repeated Falco critical detections collapse into one incident
- **GIVEN** critical Falco-promoted events that share the same configured incident grouping fields
- **WHEN** multiple matching events arrive while the incident is still active
- **THEN** the system SHALL keep a single active alert incident for that fingerprint
- **AND** duplicate events SHALL update the active incident instead of creating new alert rows

#### Scenario: A new incident is created after the previous incident is no longer active
- **GIVEN** an earlier event-derived incident has been resolved or aged out of its suppression window
- **WHEN** a matching event arrives again
- **THEN** the system SHALL create a new alert incident
- **AND** the new incident SHALL remain linked to the triggering event

### Requirement: Duplicate event bursts SHALL NOT trigger repeated immediate notification attempts
The system SHALL suppress repeated immediate notification attempts for duplicate event-derived alerts while an incident remains active and inside its cooldown window.

#### Scenario: Duplicate events arrive while outbound notification is unavailable
- **GIVEN** an active event-derived incident with an initial notification attempt already recorded
- **AND** outbound webhook notification is unavailable
- **WHEN** duplicate matching events arrive inside the cooldown window
- **THEN** the system SHALL NOT perform a new immediate notification attempt for each duplicate event
- **AND** it SHALL NOT emit one warning log per duplicate event for the same incident burst

#### Scenario: Sustained incident is re-notified after the configured interval
- **GIVEN** an active incident with `renotify_seconds` configured
- **WHEN** the incident remains active beyond the renotify interval
- **THEN** the system SHALL attempt a repeat notification at the configured interval
- **AND** duplicate events before that interval SHALL remain suppressed for immediate notification

### Requirement: Incident suppression SHALL preserve observability provenance
The system SHALL preserve source-event provenance when duplicate events are suppressed into an existing incident.

#### Scenario: Duplicate event updates incident audit data
- **GIVEN** an active event-derived incident
- **WHEN** a duplicate matching event is associated with that incident
- **THEN** the incident SHALL record updated occurrence metadata including at least occurrence count and last-seen time
- **AND** operators SHALL be able to inspect the grouping context that caused the event to be suppressed into that incident
