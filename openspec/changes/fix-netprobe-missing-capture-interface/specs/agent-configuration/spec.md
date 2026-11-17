## ADDED Requirements

### Requirement: Absent netprobe capture interfaces degrade capture instead of stopping netprobe
netprobe SHALL resolve its configured `capture_interfaces` against the host's
network interfaces at startup, capture only on the configured interfaces that
exist, and keep running when one or more of them do not exist.

When at least one configured interface is absent, netprobe SHALL report
`STATUS_DEGRADED` from AddonService `Health`, with a `degradation_reason` that
names each absent interface and lists the interfaces the host does have, and
with structured `details` keys `capture_interfaces.missing`,
`capture_interfaces.active` and `capture_interfaces.available`. When none of the
configured interfaces exist, netprobe SHALL run attribution-only. An empty
`capture_interfaces` SHALL remain attribution-only and report healthy.

#### Scenario: Configured interface absent on the host
- **GIVEN** a netprobe config with `capture_interfaces: ["eth-test0"]`
- **AND** the host has no interface named `eth-test0`
- **WHEN** netprobe starts
- **THEN** it does not exit
- **AND** flow attribution runs
- **AND** `Health` reports `STATUS_DEGRADED` with a reason naming `eth-test0` and
  the host's interfaces

#### Scenario: Some configured interfaces present
- **GIVEN** `capture_interfaces: ["eth-test0", "eth-test1"]` and the host has only
  `eth-test1`
- **WHEN** netprobe starts
- **THEN** capture runs on `eth-test1`
- **AND** `Health` reports `STATUS_DEGRADED` naming `eth-test0` as absent

#### Scenario: No capture interfaces configured
- **GIVEN** `capture_interfaces: []`
- **WHEN** netprobe starts
- **THEN** it runs attribution-only and `Health` reports `STATUS_HEALTHY`

### Requirement: netprobe restart checks compare the requested capture interfaces
netprobe SHALL decide whether a pushed config requires a restart by comparing its
`capture_interfaces` with the list netprobe was started with as configured, not
with the subset that was present on the host.

#### Scenario: Identical config pushed to a degraded netprobe
- **GIVEN** netprobe started with `capture_interfaces: ["eth-test0"]` and
  `eth-test0` absent
- **WHEN** the agent pushes a config with the same `capture_interfaces`
- **THEN** netprobe accepts it without requiring a restart

### Requirement: Agent reports netprobe AddonService health degradation
The agent SHALL query netprobe's AddonService `Health` after each successful
liveness probe and SHALL report a `STATUS_DEGRADED` answer as add-on state
`degraded` with the add-on's `degradation_reason`. A degraded netprobe SHALL
still count as running for capability reporting, and core SHALL record a
`degraded` add-on status as active.

An unreachable AddonService SHALL NOT change the liveness-derived state, because
older netprobe builds do not serve it.

#### Scenario: Degraded netprobe surfaces its reason
- **GIVEN** netprobe answers liveness probes and its `Health` returns
  `STATUS_DEGRADED` with reason "capture interface eth-test0 not present"
- **WHEN** the agent reports add-on status
- **THEN** the `addon:netprobe` status has state `degraded` and that reason as
  its last error
- **AND** core stores the row with `active = true` and that
  `degradation_reason`

#### Scenario: Health recovers
- **GIVEN** the agent reported netprobe as `degraded`
- **WHEN** a later `Health` call returns `STATUS_HEALTHY`
- **THEN** the agent reports state `running` with no last error

### Requirement: Systemd add-on crash loops are bounded and visible
The netprobe systemd unit SHALL bound automatic restarts with a start limit, and
the agent SHALL report a systemd add-on unit that stopped on its start limit as
`circuit_open` with the unit's failure detail.

While the add-on's assignment artifact and config are unchanged, the agent SHALL
NOT reinstall or restart a unit in that state. When the assignment changes, the
agent SHALL clear the unit's failed state before starting it, so the new content
gets a fresh restart budget.

When a systemd add-on's unit is not running, the agent SHALL report the unit's
state rather than the add-on's IPC reachability error.

#### Scenario: Deterministic startup failure
- **GIVEN** a systemd add-on that exits non-zero on every start
- **WHEN** it has failed five times inside the start-limit interval
- **THEN** systemd stops restarting it
- **AND** the agent reports the add-on as `circuit_open` with the failure detail
- **AND** later config cycles with the same assignment do not reinstall or
  restart it

#### Scenario: Operator fixes the assignment
- **GIVEN** a systemd add-on reported `circuit_open`
- **WHEN** its assignment config changes
- **THEN** the agent reinstalls the unit, clears its failed state and starts it

### Requirement: Core flags capture interfaces absent from the agent's inventory
Core SHALL record, for each agent targeted by a netprobe assignment, any
configured capture interface that is absent from the interface inventory the
agent last reported, and SHALL show it on the add-on profile and assignment
views.

#### Scenario: Fleet profile names an interface one host lacks
- **GIVEN** a netprobe profile targeting `in:agents` with
  `capture_interfaces: ["eth-test0"]`
- **AND** agent `host01` last reported interfaces that do not include
  `eth-test0`
- **WHEN** the profile reconciles
- **THEN** the reconcile result flags `host01` with `eth-test0` absent
