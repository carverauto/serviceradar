## MODIFIED Requirements
### Requirement: Sysmon configuration delivery
The system MUST deliver sysmon configuration to agents via GetConfig.

#### Scenario: Default sysmon configuration delivered
- **WHEN** an agent registers and requests configuration
- **THEN** it receives a sysmon configuration payload
- **AND** basic CPU, memory, and disk monitoring is active

#### Scenario: Sysmon config includes disk exclusion list
- **GIVEN** a sysmon profile specifies `disk_exclude_paths`
- **WHEN** the agent receives its sysmon configuration
- **THEN** the configuration SHALL include `disk_exclude_paths`

#### Scenario: Collect all disks by default
- **GIVEN** a sysmon profile omits `disk_paths`
- **WHEN** the agent receives its sysmon configuration
- **THEN** `disk_paths` SHALL be empty to indicate collect-all behavior

#### Scenario: Example sysmon payload
- **WHEN** an agent requests configuration
- **THEN** the sysmon payload includes fields like:
  ```json
  {
    "enabled": true,
    "sample_interval": "10s",
    "collect_cpu": true,
    "collect_memory": true,
    "collect_disk": true,
    "collect_network": false,
    "collect_processes": false,
    "disk_paths": [],
    "disk_exclude_paths": [],
    "thresholds": {
      "disk_warning": "80",
      "disk_critical": "90"
    }
  }
  ```
