## ADDED Requirements

### Requirement: Sysmon metric subjects reach the analysis consumer
The anomaly analysis subject filters SHALL use a terminal multi-token wildcard (`metrics.sysmon.>`) so that the gateway's four-token sysmon subjects (`metrics.sysmon.{type}.{name}`) are delivered to and accepted by the analysis pipeline.

#### Scenario: Four-token sysmon subject
- **WHEN** the gateway publishes `metrics.sysmon.sysmon_cpu.cpu_usage_percent`
- **THEN** the analysis stream's `filter_subject` and the pipeline `subject_enabled?` gate both match it and the sample is analyzed

### Requirement: JetStream durable recreated on filter-subject drift
Because NATS JetStream forbids changing a durable consumer's `filter_subject` via `CONSUMER.UPDATE`, the system SHALL detect when an existing anomaly durable's `filter_subject` differs from the configured subject and delete-and-recreate the durable so the corrected filter takes effect.

#### Scenario: Stale durable after a subject fix
- **WHEN** the configured sysmon subject changes from `metrics.sysmon.*` to `metrics.sysmon.>` but the durable was created with the old filter
- **THEN** the system recreates the durable with the new `filter_subject` instead of leaving the stale filter in place
