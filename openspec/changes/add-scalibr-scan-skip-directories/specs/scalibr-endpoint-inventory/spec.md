## ADDED Requirements

### Requirement: Built-In Scan Skip Directories
The ScaLibr endpoint inventory scanner SHALL skip a built-in set of directories on every filesystem walk, even when operator `dirs_to_skip` is empty or omits those paths.

The built-in set SHALL include `/proc`, `/sys`, `/dev`, `/run`, `/tmp`, `/var/tmp`, `/var/cache`, `/var/lib/docker`, `/var/lib/containerd`, `/var/lib/rancher`, `/var/lib/kubelet`, `/var/lib/containers`, `/var/lib/buildah`, `/var/lib/buildbuddy`, and `/var/lib/serviceradar/endpoint-inventory`.

#### Scenario: Empty operator skip list still skips safety trees
- **GIVEN** a `scalibr-endpoint-inventory` config with `scan_roots` of `/` and an empty `dirs_to_skip`
- **WHEN** the scanner runs
- **THEN** it SHALL NOT visit inodes under the built-in skip directories
- **AND** it SHALL still collect host OS packages from supported package databases outside those trees

#### Scenario: Delivered skip list cannot drop built-in skips
- **GIVEN** a delivered config whose `dirs_to_skip` is only `/var/cache`
- **WHEN** the scanner runs
- **THEN** it SHALL still skip `/proc`, `/sys`, `/dev`, `/run`, and the other built-in paths
- **AND** it SHALL also skip `/var/cache`

### Requirement: Operator Skip Directories Are Additive
The ScaLibr endpoint inventory scanner SHALL skip every valid operator `dirs_to_skip` path in addition to the built-in set.

#### Scenario: Operator skip excludes a data mount
- **GIVEN** `scan_roots` includes `/`
- **AND** `dirs_to_skip` includes `/mnt/build-cache`
- **WHEN** the scanner walks `/`
- **THEN** it SHALL skip `/mnt/build-cache` and all descendants
- **AND** it SHALL continue walking other directories under `/` that are not skipped

#### Scenario: Invalid skip paths are ignored
- **GIVEN** `dirs_to_skip` contains a relative path and an absolute path outside every scan root
- **WHEN** the scanner runs
- **THEN** those entries SHALL NOT fail the scan
- **AND** diagnostics SHALL record that they were ignored

### Requirement: Effective Skip List Is Diagnosed
The ScaLibr endpoint inventory scanner SHALL publish the effective skip directory list that the walk used.

#### Scenario: Diagnostics show the union
- **GIVEN** built-in skips and an operator `dirs_to_skip` of `/mnt/build-cache`
- **WHEN** the scanner completes
- **THEN** scanner activity metadata `dirs_to_skip` SHALL include the built-in paths and `/mnt/build-cache`
- **AND** it SHALL NOT list only the operator-supplied paths
