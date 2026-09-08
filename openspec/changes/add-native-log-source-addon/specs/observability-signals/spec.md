## ADDED Requirements

### Requirement: Add-on-emitted DNS security events
The system SHALL ingest DNS security events emitted by native log source add-ons as OCSF DNS Activity events (class_uid 4003, category_uid 4) with source provenance suitable for threat intelligence correlation. DNS events SHALL include tenant/partition, agent identity, DNS server identity, client endpoint, queried domain, query type, response code, and — when a policy decision is present — the OCSF Security Control fields (`action_id`, `disposition_id`) and the `firewall_rule` object carrying the RPZ policy name, match dimension, trigger, and hit. RPZ policy data SHALL be carried in these native OCSF fields rather than in `unmapped`. These derived OCSF events SHALL be eligible for the existing log-to-event/alert promotion rules so blocked-domain activity can escalate to stateful alerts.

#### Scenario: RPZ hit is queryable as an OCSF DNS Activity event
- **GIVEN** a PowerDNS native log source add-on emits an RPZ hit event
- **WHEN** the event is persisted in ServiceRadar observability storage
- **THEN** the event SHALL be classified as OCSF DNS Activity (class_uid 4003) with `disposition_id` and `action_id` reflecting the RPZ action
- **AND** the event SHALL be queryable by queried domain, client IP, DNS server, policy name, and policy action
- **AND** the event SHALL include gateway-attested tenant/partition and agent provenance

#### Scenario: DNS event preserves re-projection metadata
- **GIVEN** a PowerDNS DNS security event is persisted
- **WHEN** the OCSF mapping or schema version changes in a future release
- **THEN** the stored event SHALL retain the OCSF schema version and enough source metadata to re-project or reinterpret the event
- **AND** the system SHALL NOT require storing unbounded raw protobuf payloads by default

### Requirement: Raw DNS firehose is opt-in
The system SHALL treat full DNS query/response logging as an explicit opt-in mode separate from default RPZ/policy-hit telemetry.

#### Scenario: Default DNS telemetry avoids raw query volume
- **GIVEN** the PowerDNS native log source add-on is configured with defaults
- **WHEN** clients perform normal DNS queries that do not match RPZ or policy criteria
- **THEN** those queries SHALL NOT be stored as observability events by default
- **AND** operational counters SHALL still allow operators to see received, filtered, emitted, and dropped record totals
