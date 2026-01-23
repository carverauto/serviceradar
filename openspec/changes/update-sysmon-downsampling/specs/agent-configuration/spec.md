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
