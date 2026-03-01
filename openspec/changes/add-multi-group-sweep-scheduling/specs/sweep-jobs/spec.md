## MODIFIED Requirements
### Requirement: Sweep Job Compiled Config Output

The system SHALL compile sweep job configurations into the agent-consumable JSON format matching the existing `sweep.json` schema, preserving sweep groups as distinct entries in the `groups` array.

#### Scenario: Compile sweep config for agent
- **GIVEN** one or more sweep jobs assigned to an agent
- **WHEN** the agent polls for config
- **THEN** the compiled config SHALL include a `groups` array
- **AND** each group entry SHALL include:
  - `id` and `sweep_group_id`
  - `schedule` with `type` and `interval` or `cron_expression`
  - `targets` CIDR ranges from device query evaluation
  - `ports` from selected profile or job override
  - `modes` derived from profile or job override
  - `settings` including `concurrency`, `timeout`, and protocol settings
  - `device_targets` with per-device metadata when applicable
- **AND** group schedules SHALL NOT be merged into a single global interval

#### Scenario: Device query evaluation at compile time
- **GIVEN** a sweep job with device query "tags.env = 'prod'"
- **WHEN** the config is compiled
- **THEN** the query SHALL be evaluated against current device inventory
- **AND** matching device IPs SHALL populate `targets` as /32 CIDRs for that group
- **AND** device metadata SHALL populate `device_targets` entries for that group

#### Scenario: Multiple sweep groups remain distinct
- **GIVEN** multiple sweep jobs assigned to the same agent
- **WHEN** the agent polls for config
- **THEN** each sweep group SHALL be compiled into its own group entry
- **AND** networks, ports, and settings SHALL NOT be merged across groups
- **AND** each group SHALL retain its own schedule

#### Scenario: Agent schedules groups independently
- **GIVEN** two sweep groups with different intervals
- **WHEN** the agent applies the compiled config
- **THEN** the agent SHALL schedule and execute each group on its own interval
- **AND** execution results SHALL be attributed to the originating `sweep_group_id`

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
