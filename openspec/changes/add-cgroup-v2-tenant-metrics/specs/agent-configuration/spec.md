## ADDED Requirements
### Requirement: Configurable Cgroup-v2 Collection Scope
Agent configuration SHALL allow operators to enable cgroup-v2 collection with bounded roots and include/exclude filters.

#### Scenario: Enable scoped cgroup collection
- **WHEN** an operator configures cgroup-v2 collection for `/sys/fs/cgroup/system.slice`
- **THEN** the agent applies the configured root and filters before sysmon publishes cgroup metrics
- **AND** cgroups outside the configured scope are not collected

#### Scenario: Default behavior
- **WHEN** no cgroup-v2 collection setting is provided
- **THEN** the agent preserves existing host sysmon behavior and does not start high-cardinality per-cgroup collection implicitly
