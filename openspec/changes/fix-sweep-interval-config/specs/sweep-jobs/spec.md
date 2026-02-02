## MODIFIED Requirements
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

#### Scenario: Custom interval propagation
- **GIVEN** a sweep job with a configured interval of "6h" (21600s) provided via its profile
- **WHEN** the config is compiled
- **THEN** the `interval` field in the JSON SHALL reflect the 6 hour duration
- **AND** SHALL NOT default to 5 minutes

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
- **AND** the shortest interval SHALL be used as the global interval if intervals differ

#### Scenario: Agent parses device targets with TCP ports
- **GIVEN** a sweep config with device targets from `in:devices` query
- **AND** TCP ports configured in the sweep profile
- **WHEN** the agent receives and parses the sweep config
- **THEN** the agent SHALL parse the `device_targets` field from the gateway payload
- **AND** TCP port scans SHALL be generated for each device target using the profile ports
- **AND** both ICMP and TCP targets SHALL be created when both modes are enabled

#### Scenario: Profile ports are preserved for device-targeted sweeps
- **GIVEN** a sweep group with `target_query` using `in:devices`
- **AND** a sweep profile with non-empty TCP ports
- **AND** the sweep group does not override ports
- **WHEN** the sweep config is compiled
- **THEN** the compiled `ports` list SHALL include the profile ports
- **AND** TCP targets SHALL be generated for those ports

#### Scenario: TCP mode requires ports
- **GIVEN** a sweep group with TCP mode enabled
- **AND** no TCP ports are configured on the group or its profile
- **WHEN** the sweep config is compiled
- **THEN** the system SHALL surface a warning/error in logs
- **AND** the config SHALL NOT silently run TCP scans with an empty ports list
