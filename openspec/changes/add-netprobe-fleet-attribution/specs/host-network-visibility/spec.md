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

#### Scenario: Attribution-only CPU budget
- **GIVEN** netprobe is running with attribution enabled and packet capture/DPI disabled on representative busy Kubernetes workers
- **WHEN** CPU is sampled over a multi-minute measurement window
- **THEN** netprobe uses less than 1% sustained process CPU per worker
- **AND** ring-buffer drops do not persist
- **AND** fresh flow-to-process attribution rows continue to be streamed

### Requirement: Flow Correlation Is Protocol-Aware
The system SHALL correlate netprobe attributions to OCSF NetFlow/sFlow records
using protocol-specific tuple rules. TCP and UDP SHALL match bidirectional
5-tuples. ICMP and ICMPv6 SHALL match protocol, endpoint IPs, and time without
requiring equivalent port/type/code encoding. Node-SNAT and pod-local fallback
SHALL preserve exact local matches as higher priority than fallback candidates.

#### Scenario: UDP exact attribution
- **WHEN** a UDP netflow record and a UDP process attribution have the same bidirectional 5-tuple inside the correlation time window
- **THEN** the OCSF flow is stamped as `attributed_flow`
- **AND** the attribution payload contains the process context from netprobe

#### Scenario: ICMP exporter port mismatch
- **WHEN** an ICMP netflow record uses exporter-specific type/code pseudo-ports
- **AND** the netprobe attribution reports portless ICMP endpoints for the same local/remote IPs
- **THEN** the OCSF flow is stamped as `attributed_flow`
- **AND** the mismatch in pseudo-port encoding does not prevent attribution

#### Scenario: Pod-local attribution behind node SNAT
- **WHEN** the netflow record shows a Kubernetes node IP due to SNAT
- **AND** the attribution is observed on the same agent with a pod-local source IP and matching remote endpoint
- **THEN** the OCSF flow is stamped as `attributed_flow`
- **AND** exact host-local tuple matches rank ahead of node-SNAT fallback matches

### Requirement: Attribution Delivery Is Bounded And Observable
The system SHALL keep every attribution delivery boundary bounded and SHALL expose
drop, lag, and queue-depth signals sufficient for release gating. Burst handling
MAY coalesce status or batch attribution frames, but SHALL NOT use unbounded
queues or silently lose attribution events.

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
