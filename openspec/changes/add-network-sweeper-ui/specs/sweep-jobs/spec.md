# sweep-jobs Specification

## Purpose

Manage network sweep job configurations via UI, including scanner profiles, sweep groups with custom schedules, device targeting, and job execution tracking.

## ADDED Requirements

### Requirement: Sweep Group Management

The system SHALL provide Ash resources and UI for creating sweep groups that combine scheduling, targeting, and scan configuration.

#### Scenario: Create sweep group with custom schedule
- **GIVEN** an admin in Settings > Networks
- **WHEN** they create a new sweep group named "Network Infrastructure - Every 2 Hours"
- **AND** configure schedule to run every 2 hours
- **AND** configure ports [80, 443, 8080] with modes ["tcp", "icmp"]
- **THEN** the sweep group SHALL be saved with its unique schedule
- **AND** be available for targeting device selections

#### Scenario: Sweep group with device class filter
- **GIVEN** a sweep group configuration form
- **WHEN** the user configures targeting with:
  - discovery_sources contains "armis"
  - device_class = "network"
  - device_type in ["router", "switch", "firewall"]
- **THEN** the filter SHALL be saved as part of the sweep group
- **AND** the query SHALL be evaluated at sweep execution time

#### Scenario: Multiple sweep groups with different schedules
- **GIVEN** two sweep groups:
  - "Critical Servers - Every 5 Minutes" targeting servers
  - "Network Devices - Every 2 Hours" targeting routers/switches
- **WHEN** sweep schedules are evaluated
- **THEN** each group SHALL run on its own schedule independently
- **AND** device overlap SHALL be handled gracefully (no duplicate scans within interval)

#### Scenario: Sweep group combines multiple scan configurations
- **GIVEN** a sweep group configuration
- **WHEN** the user adds multiple scan specifications:
  - TCP ports [80, 443] with 30s timeout
  - ICMP with high-performance mode
- **THEN** both scan types SHALL be executed as part of the group sweep
- **AND** results SHALL be aggregated per device

---

### Requirement: Device Targeting DSL

The system SHALL provide a flexible device targeting language for sweep groups based on device attributes.

#### Scenario: Target by discovery source
- **GIVEN** a sweep group targeting configuration
- **WHEN** the user specifies `discovery_sources contains 'armis'`
- **THEN** the sweep SHALL target all devices with "armis" in their discovery_sources array

#### Scenario: Target by device type
- **GIVEN** a sweep group targeting configuration
- **WHEN** the user specifies `type_id in [9, 10, 12]` (firewall, switch, router)
- **THEN** the sweep SHALL target only devices matching those OCSF type IDs

#### Scenario: Target by device class
- **GIVEN** a sweep group targeting configuration
- **WHEN** the user specifies `device_class = 'network'`
- **THEN** the sweep SHALL target devices classified as network infrastructure

#### Scenario: Target by IP range
- **GIVEN** a sweep group targeting configuration
- **WHEN** the user specifies `ip in_cidr '10.0.0.0/8'`
- **THEN** the sweep SHALL target devices with IPs in the 10.x.x.x range

#### Scenario: Combined targeting criteria
- **GIVEN** a sweep group with multiple targeting criteria
- **WHEN** the criteria are:
  - discovery_sources contains 'armis'
  - device_class = 'network'
  - partition = 'datacenter-1'
- **THEN** all criteria SHALL be ANDed together
- **AND** only devices matching ALL criteria SHALL be targeted

---

### Requirement: Sweep Profile Management

The system SHALL provide Ash resources and admin UI for managing reusable scanner profiles that define available protocols, ports, and settings.

#### Scenario: Admin creates scanner profile
- **GIVEN** an admin in the Settings > Networks section
- **WHEN** they create a new scanner profile with name "Standard Web Ports"
- **AND** configure ports [80, 443, 8080, 8443] with modes ["tcp", "icmp"]
- **THEN** the profile SHALL be saved as an Ash resource
- **AND** be available for operators to use in sweep jobs

#### Scenario: Profile defines default settings
- **GIVEN** a scanner profile
- **WHEN** the profile is applied to a sweep job
- **THEN** the job SHALL inherit interval, concurrency, timeout from the profile
- **AND** operators MAY override these defaults per job

#### Scenario: Admin restricts available profiles
- **GIVEN** an admin managing scanner profiles
- **WHEN** they set a profile as "admin-only"
- **THEN** only admins SHALL be able to use that profile
- **AND** operators SHALL only see non-restricted profiles

---

### Requirement: Sweep Job Configuration

The system SHALL provide Ash resources for defining sweep jobs that target specific devices or device selections.

#### Scenario: Create sweep job from bulk device selection
- **GIVEN** a user viewing the device inventory
- **WHEN** they select multiple devices and choose "Configure Sweep"
- **THEN** a sweep job form SHALL appear with the selected devices as targets
- **AND** the user SHALL select a partition and optionally an agent
- **AND** the user SHALL select a scanner profile

#### Scenario: Create sweep job by device query
- **GIVEN** an admin in Settings > Networks
- **WHEN** they create a sweep job with device query criteria
- **THEN** they SHALL be able to filter by:
  - IP address range (CIDR notation)
  - Discovery sources (armis, netbox, snmp, etc.)
  - Tags or metadata
  - Partition
- **AND** the query SHALL be saved and re-evaluated on each sweep

#### Scenario: Assign sweep job to partition
- **GIVEN** a sweep job configuration
- **WHEN** the user selects a partition
- **THEN** the job SHALL be assigned to that partition
- **AND** any agent in that partition MAY execute the job if no specific agent is selected

#### Scenario: Assign sweep job to specific agent
- **GIVEN** a sweep job configuration
- **WHEN** the user selects a specific agent
- **THEN** only that agent SHALL execute the job
- **AND** the agent SHALL receive the config via its next poll

---

### Requirement: Sweep Job Compiled Config Output

The system SHALL compile sweep job configurations into the agent-consumable JSON format matching the existing `sweep.json` schema.

#### Scenario: Compile sweep config for agent
- **GIVEN** a sweep job assigned to an agent
- **WHEN** the agent polls for config
- **THEN** the compiled config SHALL include:
  - `networks`: CIDR ranges from device query evaluation
  - `ports`: from selected profile or job override
  - `sweep_modes`: ["tcp", "icmp", "tcp_connect"] based on profile
  - `interval`: scan interval duration
  - `concurrency`: parallel scan threads
  - `timeout`: per-target timeout
  - `icmp_count`, `high_perf_icmp`, `icmp_rate_limit`: ICMP settings
  - `device_targets`: per-device configurations with metadata

#### Scenario: Device query evaluation at compile time
- **GIVEN** a sweep job with device query "discovery_sources contains 'armis'"
- **WHEN** the config is compiled
- **THEN** the query SHALL be evaluated against current device inventory
- **AND** matching device IPs SHALL populate `networks` as /32 CIDRs
- **AND** device metadata SHALL populate `device_targets` entries

#### Scenario: Merge multiple sweep jobs
- **GIVEN** multiple sweep jobs assigned to the same agent
- **WHEN** the agent polls for config
- **THEN** the configs SHALL be merged into a single sweep config
- **AND** networks and device_targets SHALL be combined
- **AND** the most restrictive settings SHALL be used for shared targets

---

### Requirement: Sweep Job Admin UI

The system SHALL provide an admin interface for managing sweep jobs in Settings > Networks.

#### Scenario: View configured sweep jobs
- **GIVEN** an admin in Settings > Networks
- **WHEN** they view the sweep jobs list
- **THEN** they SHALL see all sweep jobs for the tenant
- **AND** each job SHALL display name, profile, target count, partition, agent, status

#### Scenario: View sweep job status
- **GIVEN** a configured sweep job
- **WHEN** viewing the job details
- **THEN** the status SHALL show:
  - Last execution time
  - Next scheduled execution
  - Execution duration
  - Target count and completion percentage
  - Error count and last error

#### Scenario: Edit sweep job
- **GIVEN** an existing sweep job
- **WHEN** an admin edits the job
- **THEN** changes SHALL be saved to the database
- **AND** a config invalidation event SHALL be published
- **AND** the assigned agent(s) SHALL receive updated config on next poll

#### Scenario: Delete sweep job
- **GIVEN** an existing sweep job
- **WHEN** an admin deletes the job
- **THEN** the job SHALL be removed from the database
- **AND** the agent config SHALL be recompiled without this job
- **AND** historical results SHALL be retained

---

### Requirement: Sweep Job Execution Tracking

The system SHALL track sweep job execution status and history.

#### Scenario: Agent reports sweep start
- **GIVEN** an agent beginning a sweep job execution
- **WHEN** the sweep starts
- **THEN** the agent SHALL report start event to gateway
- **AND** core SHALL update job status to "in_progress"
- **AND** the start time SHALL be recorded

#### Scenario: Agent reports sweep completion
- **GIVEN** an agent completing a sweep job
- **WHEN** the sweep finishes
- **THEN** the agent SHALL report completion event with:
  - Total hosts scanned
  - Hosts available
  - Execution duration
  - Any errors encountered
- **AND** core SHALL update job status to "completed"
- **AND** the completion time SHALL be recorded

#### Scenario: Track sweep job history
- **GIVEN** sweep job executions over time
- **WHEN** an admin views job history
- **THEN** they SHALL see past executions with:
  - Execution time
  - Duration
  - Results summary
  - Error details if any

---

### Requirement: Device Bulk Edit for Sweep Configuration

The system SHALL allow users to configure sweep settings for multiple devices via bulk edit.

#### Scenario: Bulk select devices for sweep
- **GIVEN** a user in the device inventory view
- **WHEN** they select multiple devices using checkboxes
- **AND** choose "Configure Network Sweep" from bulk actions
- **THEN** a modal SHALL appear with sweep configuration options

#### Scenario: Apply sweep config to selection
- **GIVEN** the bulk sweep configuration modal
- **WHEN** the user selects partition, profile, and optional agent
- **AND** confirms the operation
- **THEN** a sweep job SHALL be created targeting those devices
- **AND** the job SHALL use the selected devices' IPs as targets

#### Scenario: View device sweep status
- **GIVEN** a device with an active sweep job
- **WHEN** viewing the device details
- **THEN** the sweep status SHALL be displayed
- **AND** include last sweep time, availability status, and open ports
