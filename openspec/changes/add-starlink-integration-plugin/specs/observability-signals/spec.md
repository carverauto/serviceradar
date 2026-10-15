## ADDED Requirements

### Requirement: Plugin Signal Device Attribution
Core SHALL resolve a plugin-scoped device reference on ingested metrics, OCSF events and
alerts to the canonical device uid by looking it up as an `integration_id` identifier in the
gateway-attested partition, only when the reference's source prefix is one of the emitting
plugin package's declared inventory sources.

#### Scenario: Metric attributed to discovered device
- **WHEN** a plugin that declares inventory source `starlink` emits a metric whose resource device reference is `starlink:ut:<id>` and a device carries that integration identifier
- **THEN** the stored metric row's device id is that device's canonical uid

#### Scenario: Event attributed to discovered device
- **WHEN** the same plugin emits an OCSF event whose `device.uid` is `starlink:ut:<id>`
- **THEN** the stored event and any alert raised from it reference the canonical device uid

#### Scenario: Foreign source prefix
- **WHEN** a plugin emits a device reference whose source prefix is not one of its declared inventory sources
- **THEN** the reference is not resolved and the signal is not attached to any device of that source

#### Scenario: Unresolved reference does not fall back to the agent
- **WHEN** a plugin-scoped device reference matches no device
- **THEN** the signal is stored without a canonical device and an alert raised from it is not attributed to the agent's own device

### Requirement: Metric Alert Rule Admission
Core SHALL admit every stored metric point from the `metrics.>` stream that matches an
enabled `signal: metric` stateful alert rule to stateful alert evaluation, after the point
is stored. A redelivered point SHALL NOT be counted again toward a rule's window, and a
batch matching no enabled metric rule SHALL cost no database work beyond the point insert.

#### Scenario: Enabled metric rule fires on ingested metrics
- **WHEN** an enabled metric rule matches a metric name and condition, and points violating that condition arrive on `metrics.>` for one group until the rule's threshold within its window is reached
- **THEN** an alert is raised for that group

#### Scenario: Redelivered batch is not counted twice
- **WHEN** JetStream redelivers a metrics batch whose points were already stored and admitted
- **THEN** the rule's window count for that group is unchanged

#### Scenario: No enabled metric rule
- **WHEN** no `signal: metric` rule is enabled
- **THEN** metrics are stored as before and nothing is admitted to alert evaluation
