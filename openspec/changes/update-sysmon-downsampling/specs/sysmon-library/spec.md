## ADDED Requirements
### Requirement: Local Sampling with Downsampled Emission
The `pkg/sysmon` library SHALL support collecting metrics at a local sampling cadence and emitting a downsampled `MetricSample` at a separate upload cadence.

#### Scenario: Downsampled upload window
- **GIVEN** `sample_interval` is 10s and `upload_interval` is 60s
- **WHEN** the collector runs for one upload window
- **THEN** it produces a single `MetricSample` for upload
- **AND** the sample aggregates the six local samples using the configured aggregation mode(s)

#### Scenario: Backward-compatible emission
- **GIVEN** no upload interval or downsample policy is configured
- **WHEN** the collector emits metrics
- **THEN** it produces the same structure and cadence as the current single-sample behavior

### Requirement: Per-Metric Cadence
The library SHALL allow distinct sampling cadences per metric group (CPU, memory, disk, processes) to reduce expensive collections.

#### Scenario: Disk collection at reduced cadence
- **GIVEN** `disk_interval` is 60s and `cpu_interval` is 10s
- **WHEN** the collector runs for two minutes
- **THEN** CPU metrics are sampled every 10s
- **AND** disk metrics are sampled every 60s

### Requirement: Downsample Window Metadata
The library SHALL include window metadata on downsampled samples so consumers can reason about aggregation boundaries.

#### Scenario: Upload sample contains window range
- **GIVEN** a downsampled upload sample
- **WHEN** it is serialized
- **THEN** it includes the window start and end timestamps
- **AND** it includes the aggregation mode used per metric group

### Requirement: Process Rollup And Detail Modes
The `pkg/sysmon` library SHALL support a fleet-safe process rollup mode and an explicit raw detail mode.

#### Scenario: Rollup mode suppresses raw per-process rows
- **GIVEN** process collection is enabled with `process_mode: rollup`
- **WHEN** the collector emits an upload sample
- **THEN** the sample includes process count and configured top-N summary fields
- **AND** it does not emit one raw CPU and memory metric row per process

#### Scenario: Detail mode emits bounded per-process rows
- **GIVEN** process collection is enabled with `process_mode: detail` and a process limit
- **WHEN** the collector emits an upload sample
- **THEN** it emits raw per-process CPU and memory rows only up to the configured process limit
- **AND** the sample includes metadata that identifies the detail collection window

#### Scenario: Top-N mode remains bounded
- **GIVEN** process collection is enabled with `process_mode: top_n` and `process_top_n: 10`
- **WHEN** the collector emits an upload sample
- **THEN** no more than 10 process identities contribute raw detail rows per metric family
- **AND** process count rollup remains present for fleet-wide trend analysis

#### Scenario: Process telemetry is diagnostic by default
- **GIVEN** sysmon process metrics are published to JetStream and persisted to CNPG
- **WHEN** default anomaly detection and capacity planning consumers evaluate their input streams
- **THEN** they ignore `sysmon.process` metrics
- **AND** process telemetry remains available for diagnostic views and explicit future opt-in policies
