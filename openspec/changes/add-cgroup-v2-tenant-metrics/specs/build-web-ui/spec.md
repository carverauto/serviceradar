## ADDED Requirements
### Requirement: Device Cgroup Resource View
The web UI SHALL expose per-device cgroup or tenant resource usage when cgroup-v2 metrics are available.

#### Scenario: Cgroup metrics available
- **WHEN** a device has recent cgroup-v2 metrics
- **THEN** the device detail page shows a cgroup or tenant resource table with CPU, memory, process, and IO usage
- **AND** the table scopes labels to the current device so untrusted tenant or cgroup names are not presented as global identities

#### Scenario: No cgroup metrics
- **WHEN** a device has no cgroup-v2 metrics
- **THEN** the device detail page keeps the cgroup section empty or hidden without blocking the rest of the page from loading
