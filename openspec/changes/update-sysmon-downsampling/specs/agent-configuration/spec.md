## ADDED Requirements
### Requirement: Sysmon Upload Cadence
The agent SHALL emit sysmon metrics at an upload cadence that may differ from the local sampling cadence when downsampling is enabled.

#### Scenario: Upload cadence drives reporting
- **GIVEN** `sample_interval: 10s` and `upload_interval: 60s`
- **WHEN** the agent is running
- **THEN** it uploads one sysmon sample every 60 seconds
- **AND** each upload represents downsampled data from the 60-second window

## MODIFIED Requirements
### Requirement: Default Profile Contents
The system MUST provide a Default Sysmon Profile with predictable baseline values for sampling and upload cadence.

#### Scenario: Default profile contents
- **GIVEN** the Default Sysmon Profile
- **THEN** it includes:
  - `enabled: true`
  - `sample_interval: 10s`
  - `upload_interval: 10s`
  - `downsample_window: 10s`
  - `downsample_mode: avg`
  - `collect_cpu: true`
  - `collect_memory: true`
  - `collect_disk: true`
  - `collect_network: false` (opt-in due to verbosity)
  - `collect_processes: false` (opt-in due to resource usage)
  - `disk_paths: ["/"]` on Linux, `["/"]` on macOS

### Requirement: Configuration Schema
The sysmon configuration MUST follow a defined JSON schema.

#### Scenario: Valid configuration structure
- **GIVEN** a sysmon configuration file
- **THEN** it MUST conform to this structure:
```json
{
  "enabled": true,
  "sample_interval": "10s",
  "upload_interval": "60s",
  "downsample_window": "60s",
  "downsample_mode": "avg",
  "metric_intervals": {
    "cpu": "10s",
    "memory": "30s",
    "disk": "60s",
    "processes": "60s"
  },
  "collect_cpu": true,
  "collect_memory": true,
  "collect_disk": true,
  "collect_network": false,
  "collect_processes": false,
  "disk_paths": ["/", "/data"],
  "process_mode": "rollup",
  "process_top_n": 10,
  "thresholds": {
    "cpu_warning": "80",
    "cpu_critical": "95",
    "memory_warning": "85",
    "memory_critical": "95",
    "disk_warning": "80",
    "disk_critical": "90"
  }
}
```

#### Scenario: Minimal valid configuration
- **GIVEN** a configuration with only required fields
- **THEN** `{"enabled": true}` is valid
- **AND** all other fields use defaults

#### Scenario: Duration parsing
- **GIVEN** sample_interval values
- **THEN** the following formats are valid: "10s", "1m", "500ms", "2m30s"
- **AND** invalid formats cause a validation error

### Requirement: Process Telemetry Detail Mode
The sysmon configuration MUST distinguish fleet-safe process rollups from raw per-process detail so large deployments can bound raw row volume.

#### Scenario: Default process mode is rollup
- **GIVEN** a sysmon profile enables process collection without specifying `process_mode`
- **WHEN** the profile is compiled for an agent
- **THEN** the compiled config uses `process_mode: rollup`
- **AND** raw per-process CPU and memory rows are not enabled by default

#### Scenario: Detail mode requires explicit configuration
- **GIVEN** an operator configures `process_mode: detail`
- **WHEN** the profile is compiled
- **THEN** per-process raw CPU and memory rows may be emitted
- **AND** the config MUST include bounded targeting or a bounded detail window

#### Scenario: Process metrics are excluded from default analytic engines
- **GIVEN** a sysmon profile emits process telemetry
- **WHEN** ServiceRadar builds default anomaly-detection and capacity-planning inputs
- **THEN** `sysmon.process` metrics are excluded
- **AND** CPU, memory, filesystem/disk, interface, service health, and flow aggregates remain eligible by default
