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

### Requirement: Host Visibility Assignment Is Control-Plane Driven
Host network visibility enablement SHALL be derived from persisted
control-plane/settings state rather than per-agent Helm values. The settings UI
SHALL update the authoritative host-network visibility assignment or profile
state. The control plane SHALL compile effective agent config from that state
and push config changes to connected agents through the agent-gateway command
bus/control stream. Attribution observations SHALL travel agent-up for core
persistence and correlation with independently ingested NetFlow/IPFIX; the
production design SHALL NOT require per-agent flow-collector host slices.

#### Scenario: Large fleet enable without Helm growth
- **WHEN** an operator enables host network visibility for 25,000 agents or a dynamic cohort
- **THEN** the Helm release does not add one value entry per agent
- **AND** the control plane stores the assignment/profile state in the database
- **AND** enabled agents send local attribution observations through the normal agent-up path

#### Scenario: Settings change reaches agents
- **WHEN** an operator enables or disables host network visibility from settings
- **THEN** the control plane recompiles affected agents' effective config
- **AND** agent-gateway pushes a config change over the existing command bus/control stream to each connected affected agent
- **AND** disconnected agents receive the same effective config through normal startup/config polling after reconnect

#### Scenario: Agent address changes without flow-collector routing state
- **WHEN** an enabled agent reports a new source IP or hostname
- **THEN** subsequent attribution observations carry the current local endpoints through the agent-up path
- **AND** no flow-collector route or Helm redeploy is required

#### Scenario: Temporary demo routes remain retired
- **GIVEN** static `host_slices` or `host_slice_allowlist` values exist in a demo Helm overlay
- **WHEN** agent-up attribution and core-side correlation are enabled
- **THEN** the static demo entries are removed or disabled
- **AND** production installs are not required to maintain per-agent host-slice lists in Helm

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

### Requirement: Attribution Inventory Is Event-Driven
The netprobe attribution-only path SHALL maintain process and listener inventory
from kernel lifecycle events and bounded user-space caches instead of recurring
host-wide procfs scans. Periodic snapshot emission MAY continue, but steady-state
snapshot production SHALL serialize cache state and SHALL NOT walk
`/proc/net/{tcp,tcp6,udp,udp6}` or `/proc/*/fd`.

#### Scenario: Snapshot emission avoids steady-state procfs scans
- **GIVEN** netprobe is running in attribution-only mode
- **WHEN** the process snapshot interval elapses after initial startup reconciliation
- **THEN** the emitted snapshot is produced from the event-maintained cache
- **AND** netprobe does not scan `/proc/net/{tcp,tcp6,udp,udp6}` or `/proc/*/fd`

#### Scenario: Process metadata is PID-reuse safe
- **WHEN** netprobe enriches a process for attribution
- **THEN** the process cache key includes pid/tgid plus a stable process-generation marker
- **AND** metadata from a previous process using the same PID is not reused after exit or exec

#### Scenario: Forensic metadata stays enriched
- **WHEN** netprobe emits a flow-to-process attribution
- **THEN** the event includes eBPF-derived PID/TGID/UID/GID/comm/socket tuple data as soon as available
- **AND** command-line and container identity are enriched by a bounded metadata stage keyed by process generation
- **AND** missing metadata is reported through enrichment degradation counters instead of blocking attribution emission

#### Scenario: Attribution-only CPU budget
- **GIVEN** netprobe is running with attribution enabled and packet capture/DPI disabled on representative busy Kubernetes workers
- **WHEN** CPU is sampled over a multi-minute measurement window
- **THEN** netprobe uses less than 1% sustained process CPU per worker
- **AND** ring-buffer drops do not persist
- **AND** fresh flow-to-process attribution rows continue to be streamed

### Requirement: Attribution Producer Delivery Is Bounded And Observable
The producer path SHALL keep every boundary from the eBPF ring through netprobe
IPC and into the agent's retained queue bounded and SHALL expose drop, lag, and
queue-depth signals sufficient for release gating. Burst handling MAY coalesce
or batch attribution frames, but SHALL NOT use unbounded queues or silently lose
attribution events. Gateway acknowledgement, retry ownership, and core admission
after the agent accepts an event are owned by the `flow-attribution` and
`edge-architecture` capabilities rather than this requirement.

#### Scenario: Slow IPC reader
- **GIVEN** netprobe is producing attribution events faster than the local agent can read them
- **WHEN** the bounded IPC delivery queue reaches capacity
- **THEN** netprobe records the lag or dropped event count
- **AND** memory usage remains bounded
- **AND** the release performance gate can fail on persistent drops or lag

#### Scenario: Release performance gate
- **GIVEN** a candidate release is running attribution-only netprobe on representative busy Kubernetes workers
- **WHEN** the release gate samples CPU, event drops, queue lag, cache sizes, attribution freshness, and protocol hit rates over a multi-minute window
- **THEN** the release fails if sustained process CPU exceeds 1%
- **OR** persistent drops, queue lag, cache growth, stale attribution rows, or TCP/UDP/ICMP hit-rate regressions are observed
