## MODIFIED Requirements
### Requirement: Disk metrics collection
Sysmon MUST collect disk usage metrics for configured mounts.

#### Scenario: Disk metrics collection
- **GIVEN** a list of disk paths to monitor (e.g., `["/", "/data"]`)
- **WHEN** `CollectDisks()` is called
- **THEN** sysmon SHALL collect disk usage metrics for the specified paths

#### Scenario: Collect all disks by default
- **GIVEN** `disk_paths` is empty
- **WHEN** `CollectDisks()` is called
- **THEN** sysmon SHALL collect disk usage metrics for all available mounts

#### Scenario: Exclude specific disk paths
- **GIVEN** `disk_paths` is empty and `disk_exclude_paths` contains `["/var/lib/docker"]`
- **WHEN** disk metrics are collected
- **THEN** sysmon SHALL omit metrics for `/var/lib/docker` while collecting all other mounts

#### Scenario: Selective disk paths
- **GIVEN** configuration with `disk_paths: ["/", "/var/log"]`
- **WHEN** disk metrics are collected
- **THEN** sysmon SHALL return metrics only for the configured paths

#### Scenario: Inaccessible disk path
- **GIVEN** a configured disk path that becomes inaccessible
- **WHEN** disk metrics are collected
- **THEN** sysmon SHALL skip that path without failing the overall collection
