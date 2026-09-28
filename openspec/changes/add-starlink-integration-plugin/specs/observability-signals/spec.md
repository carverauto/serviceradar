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
