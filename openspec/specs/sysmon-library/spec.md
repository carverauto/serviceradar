# sysmon-library Specification

## Purpose
TBD - created by archiving change sysmon-consolidation. Update Purpose after archive.
## Requirements
### Requirement: Cross-platform Metrics Collection

The `pkg/sysmon` library MUST provide normalized system metrics across Linux and macOS using `shirou/gopsutil` as the underlying collection mechanism.

#### Scenario: CPU metrics on Linux
- **GIVEN** the library is running on a Linux host
- **WHEN** `CollectCPU()` is called
- **THEN** it returns per-core usage percentages (0.0-100.0)
- **AND** aggregate system CPU usage
- **AND** CPU frequency data where available

#### Scenario: CPU metrics on macOS
- **GIVEN** the library is running on a macOS host
- **WHEN** `CollectCPU()` is called
- **THEN** it returns per-core usage percentages consistent with legacy `sysmon-osx`
- **AND** CPU frequency data from `gopsutil` (Intel) or estimated values (Apple Silicon)

#### Scenario: Memory metrics collection
- **WHEN** `CollectMemory()` is called on any supported platform
- **THEN** it returns used bytes, total bytes, and usage percentage
- **AND** swap/virtual memory statistics

#### Scenario: Disk metrics collection
- **GIVEN** a list of disk paths to monitor (e.g., `["/", "/data"]`)
- **WHEN** `CollectDisk()` is called
- **THEN** it returns used bytes, total bytes, and usage percentage for each path
- **AND** omits paths that don't exist or are inaccessible

#### Scenario: Network metrics collection
- **WHEN** `CollectNetwork()` is called
- **THEN** it returns bytes sent/received per interface
- **AND** packet counts and error counts

### Requirement: Sysmon-OSX Feature Parity

The library MUST incorporate all functionality from the legacy `pkg/checker/sysmonosx` implementation to ensure macOS users experience no regression.

#### Scenario: macOS CPU frequency collection
- **GIVEN** the library is running on macOS with Intel processor
- **WHEN** CPU metrics are collected
- **THEN** frequency data is obtained via `gopsutil` cpufreq package
- **AND** values match those previously returned by `sysmon-osx`

#### Scenario: macOS Apple Silicon handling
- **GIVEN** the library is running on macOS with Apple Silicon
- **WHEN** CPU frequency data is requested
- **THEN** the library returns available frequency data or gracefully handles unavailability
- **AND** does not error or crash

#### Scenario: Sample interval configuration
- **GIVEN** a sample interval of 200ms is configured
- **WHEN** continuous collection is enabled
- **THEN** metrics are collected at approximately 200ms intervals
- **AND** the interval is bounded between 50ms (minimum) and 5000ms (maximum)

### Requirement: Configurable Metric Collection

The library MUST support selective metric collection based on configuration to minimize resource usage.

#### Scenario: Disable CPU collection
- **GIVEN** configuration with `collect_cpu: false`
- **WHEN** the collector runs
- **THEN** CPU metrics are not collected
- **AND** CPU-related fields are omitted from output

#### Scenario: Selective disk paths
- **GIVEN** configuration with `disk_paths: ["/", "/var/log"]`
- **WHEN** disk metrics are collected
- **THEN** only the specified paths are monitored
- **AND** other mounted filesystems are ignored

#### Scenario: Process collection opt-in
- **GIVEN** configuration with `collect_processes: true`
- **WHEN** process metrics are collected
- **THEN** top N processes by CPU/memory are returned
- **AND** process name, PID, CPU%, and memory% are included

### Requirement: MetricSample Structure Compatibility

The library MUST produce `MetricSample` structures compatible with the existing backend data pipeline to ensure seamless integration.

#### Scenario: JSON output compatibility
- **WHEN** metrics are serialized to JSON
- **THEN** the structure matches the existing Rust sysmon output format
- **AND** existing datasvc parsers can process the data without modification

#### Scenario: Timestamp format
- **WHEN** a MetricSample is created
- **THEN** the timestamp is in RFC3339 format with microsecond precision
- **AND** is in UTC timezone

### Requirement: Embeddable Library Design

The library MUST be designed as an embeddable Go package, not a standalone service, so it can be directly integrated into `serviceradar-agent`.

#### Scenario: Library initialization
- **GIVEN** a valid `SysmonConfig` struct
- **WHEN** `NewCollector(config)` is called
- **THEN** a Collector instance is returned ready for use
- **AND** no network listeners are started

#### Scenario: Graceful shutdown
- **GIVEN** a running Collector with active metric collection
- **WHEN** `collector.Stop()` is called
- **THEN** the collector stops collecting metrics
- **AND** releases all system resources
- **AND** can be restarted with new configuration

#### Scenario: Concurrent safety
- **GIVEN** a Collector instance
- **WHEN** multiple goroutines call collection methods simultaneously
- **THEN** the library handles concurrent access safely
- **AND** no data races occur

### Requirement: Error Handling and Resilience

The library MUST handle collection failures gracefully without crashing the host agent.

#### Scenario: Inaccessible disk path
- **GIVEN** a configured disk path that becomes inaccessible
- **WHEN** disk metrics are collected
- **THEN** an error is logged for that path
- **AND** metrics for accessible paths are still returned
- **AND** the collector continues operating

#### Scenario: Partial collection failure
- **GIVEN** CPU collection succeeds but memory collection fails
- **WHEN** a full collection cycle runs
- **THEN** the successful CPU metrics are returned
- **AND** the memory failure is logged
- **AND** the MetricSample indicates which metrics are valid

#### Scenario: System under load
- **GIVEN** the host system is under extreme load
- **WHEN** collection takes longer than the sample interval
- **THEN** the collector skips overlapping collection cycles
- **AND** logs a warning about collection delays

