## ADDED Requirements

### Requirement: Agents Attest Connection Capture Coverage Per Interval
Netprobe SHALL publish one capture coverage attestation for each connection summary interval, after every summary row of that interval (as defined by *Hosts Report Per-Process Connection Summaries As Evidence*) has been acknowledged. Core SHALL publish attestations on `flows.connections.coverage` in the `flow_connections` stream, and EventWriter SHALL append them to the StarRocks table `agent_capture_coverage`.

**Content.** The attestation SHALL state:
- the interval bounds, `capture_mode` (`event_driven`, `polling` or `degraded`) and `netns_scope` (`host` or `all`);
- a digest of the agent's current address leases;
- kernel events lost;
- ownership events shed by the per-agent event budget, by reason;
- the number of summary rows emitted and the highest summary aggregation level reached;
- maximum publish lag, backpressure, and whether netprobe restarted in the interval;
- the clock offset and clock sync state.

**Completeness.** `complete` SHALL be true only when all of these hold:
- the capture mode is `event_driven`;
- no kernel event was lost and no ownership event was shed;
- no summary row was aggregated beyond the `peer_ip` level;
- no restart occurred, publish lag is within bound, and no backpressure occurred.

**Gaps.** An interval with no attestation SHALL be treated as having no coverage claim.

**Independence from attribution.** Attestations are coverage evidence only. The ownership index MUST NOT read them, and attribution MUST NOT depend on them.

#### Scenario: Healthy interval attests complete
- **GIVEN** event-driven capture with no loss, no shedding, no restart, lag within bound, and summaries below the per-agent cap
- **WHEN** the interval closes and its summary rows are acknowledged
- **THEN** an attestation with `complete = true`, the emitted row count and aggregation level `none` is published

#### Scenario: Ring buffer loss voids completeness
- **GIVEN** the kernel ring buffer dropped 4 events during the interval
- **WHEN** the attestation is published
- **THEN** `kernel_events_lost = 4` and `complete = false`

#### Scenario: Summary aggregation beyond peer address voids completeness
- **GIVEN** an agent's summaries for an interval reached the `service` or `overflow` aggregation level
- **WHEN** the attestation is published
- **THEN** it reports that level and `complete = false`

#### Scenario: Shed renewal voids completeness
- **GIVEN** the per-agent event budget shed lease renewals during the interval
- **WHEN** the attestation is published
- **THEN** it reports the shed count by reason and `complete = false`

#### Scenario: Restart gap has no claim
- **GIVEN** netprobe restarted mid-interval
- **WHEN** the attestation is published
- **THEN** `restarted = true` and `complete = false`

### Requirement: Flow Rows Record Per-Side Attribution Outcome And Device Ordinal
In addition to the owner columns written by *Flows Are Attributed On Ingest By Key Lookup*, the EventWriter flow tier SHALL stamp each flow row with:
- `src_device_ord` and `dst_device_ord`, taken from the current exposure address dimension map;
- `src_attribution_outcome` and `dst_attribution_outcome`, each one of `attributed`, `unmonitored`, `no_owner`, `ambiguous`, `index_warming` or `error`.

**Late decisions.** A late decision published under *Late Binding Is Bounded And Never Rescans Flows* SHALL update the per-side outcomes in the same partial update and under the same decision-sequence guard as the owner columns.

**Discrepancy candidates.** After a flow's late window reaches its cutoff, the home shard SHALL publish one deduplicated discrepancy candidate per device, peer, port, protocol and minute for each side whose final outcome is `no_owner` and whose address maps to exactly one agent-managed device with address presence. Flows marked `attribution_finalized_early`, and flows carrying agent-provided attribution, SHALL NOT produce candidates.

**History.** Historical flows SHALL NOT be backfilled.

#### Scenario: Endpoint ordinal is stamped
- **GIVEN** `192.0.2.10` maps to device H in the address dimension
- **WHEN** a router-exported flow involving `192.0.2.10` is ingested
- **THEN** the flow row's side for `192.0.2.10` carries H's ordinal and that side's attribution outcome
- **AND** the flow's exporter `device_uid` is unchanged

#### Scenario: Late decision updates the outcome
- **GIVEN** a flow side was written with outcome `no_owner`
- **WHEN** a late decision with a higher decision sequence attributes that side
- **THEN** the side's outcome becomes `attributed` in the same partial update as its owner columns

#### Scenario: Candidate only after the cutoff
- **GIVEN** a flow side on an address with presence, owned by one agent-managed device, still has no owner at its late-window cutoff
- **WHEN** the cutoff passes
- **THEN** exactly one discrepancy candidate is published for that device, peer, port, protocol and minute

#### Scenario: Early finalization produces no candidate
- **GIVEN** a flow whose decision state was finalized early under budget pressure
- **WHEN** its decision is final
- **THEN** the row carries `attribution_finalized_early`, and no candidate is published

#### Scenario: Warming shard produces no candidate
- **GIVEN** the ownership shard for the side's key is warming
- **WHEN** the flow is ingested
- **THEN** the side's outcome is `index_warming`, and no candidate is published
