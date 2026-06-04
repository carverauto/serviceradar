## ADDED Requirements

### Requirement: Attribution Runs Without Capture Configuration
Enabling the netprobe add-on SHALL run the eBPF process-attribution path with no
capture interfaces or device bindings configured. The agent SHALL launch and keep
netprobe running whenever the visibility config is enabled, independent of capture
settings, because the attribution kprobes are kernel-wide and require no interface
allowlist.

#### Scenario: Enable-only attribution
- **WHEN** an operator assigns netprobe with `enabled: true` and no capture interfaces or device bindings
- **THEN** the agent starts netprobe and the eBPF kprobe attribution path runs
- **AND** flow-to-process attributions are produced and streamed without any interface configuration

#### Scenario: Disabled stays down
- **WHEN** the visibility config is `enabled: false`
- **THEN** the agent does not run netprobe capture and no attributions are produced

### Requirement: Fleet-Wide Attribution Assignment
A single add-on assignment SHALL be sufficient to enable attribution across an
arbitrary number of agents, without per-agent interface configuration.

#### Scenario: Cohort enable
- **WHEN** an operator enables netprobe for a cohort of N agents with no interface config
- **THEN** every compatible agent in the cohort runs attribution
- **AND** the operator is not required to provide per-agent NIC names

### Requirement: Capture And DPI Are Optional Advanced Settings
Packet capture and DPI configuration SHALL be optional and SHALL NOT be required to
enable the add-on. The affected fields — `capture_interfaces`, `dpi`,
`default_sample_interval_ms`, `external_flow_match_window_ms`, and `device_bindings`
— SHALL be presented by the operator configuration form as advanced settings,
collapsed by default, with attribution enabled by the master toggle alone.

#### Scenario: Advanced fields not required
- **WHEN** an operator opens the netprobe assignment form
- **THEN** only the Enable toggle is required to submit
- **AND** the capture/DPI/device-binding fields are shown in a collapsed advanced section

#### Scenario: Opt-in capture still works
- **WHEN** an operator expands advanced settings and sets capture interfaces
- **THEN** netprobe additionally performs packet capture/DPI on those interfaces
- **AND** attribution continues to run unchanged
