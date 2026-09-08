## ADDED Requirements
### Requirement: Worker Alert Thresholds SHALL Derive From Authoritative Worker State
The platform SHALL derive camera analysis worker alert thresholds from the authoritative worker registry and runtime health updates.

#### Scenario: Threshold evaluation uses worker registry state
- **WHEN** worker health, flapping state, or failover outcomes change
- **THEN** the platform SHALL evaluate alert thresholds from the updated worker state
- **AND** it SHALL avoid maintaining a separate independent worker health model

### Requirement: Failover Exhaustion SHALL Produce A Worker Alert State
The platform SHALL derive a bounded worker alert state when capability-targeted analysis dispatch cannot find a healthy replacement worker.

#### Scenario: Capability failover cannot find a replacement
- **WHEN** a capability-targeted analysis worker fails and failover cannot resolve a healthy replacement
- **THEN** the platform SHALL derive an exhausted or unavailable alert state for the affected worker context
- **AND** it SHALL emit the corresponding alert transition signal
