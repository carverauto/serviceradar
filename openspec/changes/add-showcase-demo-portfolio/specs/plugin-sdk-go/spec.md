## ADDED Requirements

### Requirement: Topology link emission
The Go SDK SHALL provide a builder for `serviceradar.topology_links.v1` link observations that reference devices by the same identity keys the plugin uses in device discovery.

#### Scenario: RTU to radio link
- **WHEN** a plugin adds a link from an RTU device to a radio device with kind `wireless`
- **THEN** the submitted result SHALL contain a `serviceradar.topology_links.v1` observation with both identity keys, the kind and the observation time
