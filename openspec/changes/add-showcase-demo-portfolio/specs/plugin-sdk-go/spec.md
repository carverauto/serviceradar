## ADDED Requirements

### Requirement: Topology link emission
The Go SDK SHALL provide a builder for `serviceradar.topology_links.v1` link observations that reference devices by the same identity keys the plugin uses in device discovery.

#### Scenario: RTU to radio link
- **WHEN** a plugin adds a link from an RTU device to a radio device with kind `wireless`
- **THEN** the submitted result SHALL contain a `serviceradar.topology_links.v1` observation with both identity keys, the kind and the observation time

### Requirement: Manifest model matches the agent and real manifests
The Go SDK manifest model SHALL accept every capability the agent enforces, including `notify:v1`, and SHALL model the `actions` and `integrations` manifest sections used by first-party plugins.

#### Scenario: Manifest with notify and actions
- **WHEN** a manifest declaring `notify:v1` and an `actions` section is built with the SDK
- **THEN** the SDK SHALL accept it and preserve both sections in the serialized manifest
