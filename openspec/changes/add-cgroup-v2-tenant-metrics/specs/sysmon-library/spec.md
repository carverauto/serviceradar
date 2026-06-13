## ADDED Requirements
### Requirement: Cgroup-v2 Resource Metrics
The sysmon library SHALL collect configured cgroup-v2 resource metrics and publish them as unified metric events associated with the attested host device.

#### Scenario: Collect cgroup-v2 resource usage
- **WHEN** cgroup-v2 collection is enabled for a host with readable cgroup files
- **THEN** sysmon emits CPU, memory, process, and IO metrics for matching cgroups through the unified metric event envelope
- **AND** each metric includes cgroup identity attributes such as path, slice, tenant or account label, container metadata, and Kubernetes metadata when available

#### Scenario: Host without cgroup-v2 support
- **WHEN** cgroup-v2 collection is enabled on a host without a mounted cgroup-v2 hierarchy
- **THEN** sysmon reports the unsupported state without failing unrelated host metric collection

### Requirement: Per-Cgroup Reset Anchors
The sysmon library SHALL attach reset anchors to cumulative cgroup counters that identify the cgroup instance, not just the host boot instance.

#### Scenario: Cgroup recreated without reboot
- **WHEN** a cgroup path is deleted and recreated while the host remains online
- **THEN** sysmon emits a new reset anchor for counters from the recreated cgroup
- **AND** downstream consumers treat subsequent lower counter values as a reset rather than a wrap
