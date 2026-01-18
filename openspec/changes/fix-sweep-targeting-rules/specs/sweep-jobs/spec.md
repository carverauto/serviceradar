## MODIFIED Requirements

### Requirement: Device Targeting DSL

The system SHALL provide a flexible device targeting language for sweep groups based on device attributes, with full round-trip persistence through the UI.

#### Scenario: Target by tag key
- **GIVEN** a sweep group targeting configuration
- **WHEN** the user specifies `tags has_any ['critical']`
- **THEN** the sweep SHALL target all devices with the "critical" tag key

#### Scenario: Target by tag key/value
- **GIVEN** a sweep group targeting configuration
- **WHEN** the user specifies `tags.env = 'prod'`
- **THEN** the sweep SHALL target devices with `tags.env` set to "prod"

#### Scenario: Target by IP range
- **GIVEN** a sweep group targeting configuration
- **WHEN** the user specifies `ip in_cidr '10.0.0.0/8'`
- **THEN** the sweep SHALL target devices with IPs in the 10.x.x.x range

#### Scenario: Target by static targets
- **GIVEN** a sweep group targeting configuration
- **WHEN** the user provides static targets `["10.0.0.10", "10.0.2.0/24"]`
- **THEN** the sweep SHALL always include those targets
- **AND** merge them with tag-based criteria results

#### Scenario: Combined targeting criteria
- **GIVEN** a sweep group with multiple targeting criteria
- **WHEN** the criteria are:
  - tags has_any ['critical', 'prod']
  - ip in_cidr '10.0.0.0/8'
  - partition = 'datacenter-1'
- **THEN** the criteria SHALL support boolean grouping (all/any)
- **AND** only devices matching the configured logic SHALL be targeted

#### Scenario: Targeting criteria round-trip persistence
- **GIVEN** a sweep group with targeting criteria configured via the SRQL builder
- **WHEN** the user saves the sweep group
- **AND** the user opens the sweep group for editing
- **THEN** the SRQL builder SHALL display all previously configured targeting rules
- **AND** the rules SHALL be editable and resavable without data loss

#### Scenario: Targeting criteria validation feedback
- **GIVEN** a sweep group form with invalid targeting criteria
- **WHEN** the user attempts to save the sweep group
- **THEN** the system SHALL display a validation error message
- **AND** the message SHALL indicate which criteria field is invalid

---

### Requirement: Sweep Job Compiled Config Output

The system SHALL compile sweep job configurations into the agent-consumable JSON format matching the existing `sweep.json` schema, with partition-aware delivery.

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
- **GIVEN** a sweep job with device query "tags.env = 'prod'"
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

#### Scenario: Partition-aware sweep config delivery
- **GIVEN** a sweep group configured with partition "datacenter-1"
- **AND** an agent registered with partition "datacenter-1"
- **WHEN** the agent polls for config
- **THEN** the agent SHALL receive sweep groups matching its registered partition
- **AND** sweep groups with partition "default" and agent_id=nil SHALL also be included

#### Scenario: Agent receives updated config after sweep group change
- **GIVEN** an agent with an existing sweep configuration
- **WHEN** an admin modifies a sweep group's targeting criteria
- **THEN** the config cache SHALL be invalidated
- **AND** the agent SHALL receive the updated config on next poll
- **AND** the config version hash SHALL change to reflect the update

---

## ADDED Requirements

### Requirement: Sweep Config Debugging

The system SHALL provide observability into sweep configuration compilation and delivery for troubleshooting.

#### Scenario: View compiled sweep config for agent
- **GIVEN** an admin in the admin console
- **WHEN** they select an agent to inspect
- **THEN** they SHALL be able to view the compiled sweep configuration
- **AND** see which sweep groups are included
- **AND** see the resolved target list

#### Scenario: Trace sweep config compilation
- **GIVEN** a sweep configuration compilation occurs
- **WHEN** the compilation completes
- **THEN** the system SHALL log:
  - Number of sweep groups loaded
  - Number of targets resolved per group
  - Config hash generated
  - Compilation duration
- **AND** these metrics SHALL be available via telemetry
