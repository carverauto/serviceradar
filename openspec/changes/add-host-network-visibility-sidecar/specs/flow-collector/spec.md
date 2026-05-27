## ADDED Requirements

### Requirement: Per-host slice publication for netprobe attribution

`flow-collector` SHALL publish a per-host slice of ingested NetFlow /
sFlow records to a dedicated NATS subject for each agent that has
advertised the `host-network-visibility` capability. A slice MUST
contain only those flow records whose source or destination IP belongs
to the target agent's host IP set, and slice publication MUST be
partition-scoped so an agent only ever receives records from its own
tenant.

#### Scenario: Agent without the capability receives no slice
- **WHEN** an agent does not advertise `host-network-visibility` (or
  advertises it as `unavailable`)
- **THEN** `flow-collector` does not publish a per-host slice for that
  agent

#### Scenario: Slice contains only records touching the target host
- **WHEN** `flow-collector` ingests a NetFlow record whose source and
  destination IPs are unrelated to a given agent's host IP set
- **THEN** the record is not published on that agent's per-host slice

#### Scenario: Slice is partition-scoped
- **WHEN** two tenants each operate an agent advertising the
  capability
- **THEN** each tenant's agent receives only flow records ingested
  under its own partition

### Requirement: Attributed flow event type

The flow pipeline SHALL define an `attributed_flow` event type
carrying the original NetFlow / sFlow fields plus the attribution
fields produced by `netprobe` (`pid`, `comm`, redacted `cmdline`,
`uid`, `container_id`). Records that pass through a `netprobe`-enabled
agent and match a local socket MUST be republished as
`attributed_flow`; records that do not match MUST continue to flow as
the unattributed event type without modification.

#### Scenario: Matched flow becomes attributed
- **WHEN** an agent forwards a NetFlow record to `netprobe` and
  `netprobe` matches it to a local socket owned by PID 1234
- **THEN** the agent republishes the record as an `attributed_flow`
  event with `pid = 1234`
- **AND** the original unattributed copy is not double-published

#### Scenario: Unmatched flow remains unattributed
- **WHEN** an agent forwards a NetFlow record that does not match any
  local socket within the matching window
- **THEN** the record continues through the existing flow pipeline as
  the unattributed event type

### Requirement: Per-slice observability metrics

`flow-collector` SHALL expose per-slice counters reporting records
published, bytes published, and subscribers active for each per-host
slice, in addition to the existing per-listener metrics defined in
`Per-listener observability metrics`.

#### Scenario: Slice metrics reflect publication activity
- **WHEN** `flow-collector` publishes 100 records on an agent's
  per-host slice within a metric collection window
- **THEN** the slice's `_records_published_total` metric reports 100
  more than the prior window's value
