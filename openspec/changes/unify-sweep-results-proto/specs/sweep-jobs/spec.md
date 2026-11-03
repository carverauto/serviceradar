# sweep-jobs Delta

## ADDED Requirements

### Requirement: Leased sweep slots execute their signed plan
A leased sweep slot SHALL execute exactly the checks, ports and targets its
signed plan carries. The agent's sweep config SHALL NOT determine or veto the
checks, ports or targets of a leased slot. That config SHALL remain
authoritative only for unleased and legacy sweep groups, and for leased groups
only for scanner settings that no record claims. Every `SweepLeaseV1` push that
carries slots SHALL use `lease_version` 2 and SHALL carry, in `check_sets`, one
`SweepCheckSetV1` per distinct `check_set_sha256` among the slots in that
push. The carried checks SHALL be the sorted, de-duplicated `(mode, protocol,
port)` list whose check-set digest is that key. Core SHALL NOT send a check
set that no slot in the push references. The agent SHALL keep the carried
sets its installed slots still reference. A tail push carries check sets only
for the slots in that push, and a retained slot whose start lies outside the
push window SHALL resolve its checks from the sets kept for it. Core SHALL
lease a sweep group only to an agent that reports
`sweep_lease_plan_checks:v1`. A push with no slots SHALL use `lease_version`
1. When that push has `revoked` true, the agent SHALL withdraw the lease and
the group's local ticker SHALL resume. When `revoked` is false, the agent
SHALL accept the push and merge it as `mergeSweepLease` does. The same lease
id SHALL drop installed slots whose start lies in the push window, SHALL keep
the installed production capability when the push carries none, SHALL
normalize the window to the slots still held when any remain, and SHALL keep
the push window when none remain. A different
lease id SHALL replace the installed lease outright, so no previous-epoch
slot keeps running, and that stored lease SHALL take the push's
`lease_version`. A slot-less same-lease merge SHALL keep the installed
lease's `lease_version` and the check sets its retained slots reference, and
SHALL NOT lower that version. A push that carries slots SHALL store its own
`lease_version`, which is 2. `mergeSweepLease` clones the push today, which
stores a slot-less push at `lease_version` 1; M2.0i4 changes that slot-less
same-lease merge so it never lowers the stored version. The ticker SHALL stay
suppressed while the merged lease is held. On load, the agent SHALL discard a
stored lease whose `lease_version` is not 2 and that carries slots. A
slot-less same-lease merge that kept an installed `lease_version` 2 still
carries those slots, so that discard SHALL NOT drop it or resume its
ticker. The agent SHALL keep a held lease that has no slots so that group's
ticker stays suppressed. A push that carries slots at
`lease_version` 1 SHALL be refused. `sweep_lease_plan_checks:v1` names digest
grammar 1, and core SHALL NOT send a check set whose `digest_version` the
agent did not advertise. Before install, the agent SHALL validate the push's
carried check sets against the slots in that push. An unknown
`digest_version`, a carried set whose checks digest to a different value, a
slot in the push whose `check_set_sha256` matches no set in that push, a
carried set no slot in the push references, or a set that does not decode
SHALL fail that push with a `SweepLeaseAck` error before install. The failure
SHALL refuse only that push. Any previously installed valid lease SHALL stay
in force and SHALL keep the group's local ticker suppressed. The agent SHALL
fall back to the local ticker only when no valid installed lease covers the
group (never installed, revoked, or expired). For an installed slot, the only
comparison the agent makes between the slot and its checks SHALL be that the
digest of the carried checks equals the slot's `plan_header.check_set_sha256`.
An agent that cannot run an installed carried check SHALL refuse the slot
with a typed reason and SHALL NOT run a subset or a substitute of the signed
checks. Slot refusals SHALL be execution-time only. `CHECK_UNAVAILABLE` SHALL
name the marker of a carried mode the agent cannot run now: `icmp.unavailable`
or `mtr.unavailable` for that mode, and `tcp_syn_ipv6.unavailable` for IPv6
raw SYN. The next lease pass SHALL withhold `icmp` or `mtr` for an agent
reporting that mode's marker. The planner SHALL NOT lease a group whose check
set would need IPv6 SYN to an agent reporting `tcp_syn_ipv6.unavailable`.
`UNSUPPORTED_PLAN` SHALL be the slot refusal when an installed carried set is
one the executor cannot express, such as TCP modes that do not share one port
list. A refusal for the same assignment and lease SHALL move a slot from
`missed_offline` or `missed_exhausted` to `refused`, and `refused` SHALL be
terminal.

#### Scenario: Config differs from the signed plan
- **GIVEN** an installed slot whose carried checks digest to its header's
  `check_set_sha256`
- **AND** the agent's sweep config for the group now lists different modes,
  ports or networks
- **WHEN** the slot runs
- **THEN** the scanner SHALL probe the plan ranges' CIDRs with the carried modes
  and ports
- **AND** every batch's `tested_checks` SHALL equal the carried checks
- **AND** a config update during the run SHALL NOT change that execution

#### Scenario: Carried checks fail validation before install
- **GIVEN** a valid lease for the group is already installed
- **WHEN** a replacement push carries an unknown check-set `digest_version`,
  a set whose checks digest to a different value than its key, a slot in the
  push whose `check_set_sha256` matches no set in that push, a carried set no
  slot in the push references, or a set that does not decode
- **THEN** the agent SHALL refuse that push with a `SweepLeaseAck` error
  before install
- **AND** SHALL NOT fall back to checks derived from its config
- **AND** the previously installed lease SHALL stay in force and SHALL keep
  the group's local ticker suppressed

#### Scenario: Same-lease empty push clears the window
- **GIVEN** a valid lease for the group is already installed
- **WHEN** core pushes `lease_version` 1 with no slots, `revoked` false, and
  that same lease id
- **THEN** the agent SHALL drop installed slots whose start lies in the push
  window
- **AND** SHALL keep the installed production capability
- **AND** SHALL normalize the window to the slots still held when any remain
- **AND** SHALL keep the push window when none remain
- **AND** SHALL keep the installed lease's `lease_version`
- **AND** SHALL keep the check sets its retained slots reference
- **AND** SHALL NOT resume the local ticker

#### Scenario: A started slot survives a same-lease empty push
- **GIVEN** an installed lease at `lease_version` 2 whose slot has already
  started
- **AND** the agent holds the carried set that slot references
- **WHEN** core pushes `lease_version` 1 with no slots, `revoked` false, and
  that same lease id, in a window that starts after the slot
- **THEN** the agent SHALL store the merge at `lease_version` 2
- **AND** SHALL keep the carried set that slot references
- **AND** after the agent loads its stored leases, that lease SHALL still be
  installed and the local ticker SHALL stay suppressed
- **AND** the started slot SHALL resume from that carried plan

#### Scenario: A different lease id with no slots replaces the lease
- **GIVEN** a valid lease for the group is already installed
- **WHEN** core pushes `lease_version` 1 with no slots, `revoked` false, and
  a different lease id
- **THEN** the agent SHALL replace the installed lease with that push
- **AND** the stored lease SHALL take that push's `lease_version`
- **AND** no slot from the previous lease SHALL keep running
- **AND** SHALL NOT resume the local ticker

#### Scenario: A held empty lease survives reload
- **GIVEN** the agent holds a lease with no slots
- **WHEN** the agent loads its stored leases
- **THEN** it SHALL keep that lease
- **AND** SHALL NOT resume the group's local ticker

#### Scenario: Tail push retains an earlier slot
- **GIVEN** an installed slot whose start lies outside the tail window
- **AND** the agent still holds the carried set that slot references
- **WHEN** a tail push carries later slots and only the check sets those slots
  use
- **THEN** the agent SHALL install the tail
- **AND** SHALL resolve the retained slot from the set it kept
- **AND** SHALL NOT require that set to be repeated in the tail

#### Scenario: Check set the executor cannot express
- **GIVEN** a leased slot is already installed
- **WHEN** its carried set is one the executor cannot express, such as TCP
  modes that do not share one port list
- **THEN** the agent SHALL refuse the slot with reason `UNSUPPORTED_PLAN`
- **AND** SHALL NOT run a subset of the signed checks

#### Scenario: A carried mode becomes unavailable before the slot runs
- **GIVEN** a slot carries ICMP
- **AND** the agent can no longer open its ICMP sweep socket
- **WHEN** the slot is due
- **THEN** the agent SHALL report `icmp.unavailable` in its capabilities
- **AND** SHALL refuse the slot before its first append, reporting
  `SweepLeaseSlotRefusal` with reason `CHECK_UNAVAILABLE` and that marker
- **AND** core SHALL record the slot as refused with that reason, and SHALL
  NOT later mark it missed
- **AND** the next lease pass SHALL plan that agent's unrun slots from its
  capabilities without ICMP and push them as a window replacement

#### Scenario: A mode the agent would substitute
- **WHEN** a carried mode would run as a different mode for a plan range, such
  as TCP SYN on an IPv6 range without raw IPv6 SYN
- **THEN** the agent SHALL refuse the slot with reason `CHECK_UNAVAILABLE` and
  the marker `tcp_syn_ipv6.unavailable`
- **AND** SHALL NOT run the substitute mode under the signed plan
- **AND** the next lease pass SHALL NOT lease a group whose check set would
  need IPv6 SYN to this agent

#### Scenario: Refusal reported while disconnected
- **GIVEN** the agent refused a slot while its control stream was down
- **WHEN** the control stream reconnects
- **THEN** the agent SHALL re-send every refusal it still holds
- **AND** core SHALL record each one once per execution id
- **AND** a slot that is `missed_offline` or `missed_exhausted` for that same
  assignment and lease SHALL become `refused`
- **AND** `refused` SHALL stay refused

#### Scenario: Agent without plan-carried execution
- **GIVEN** an agent that does not report `sweep_lease_plan_checks:v1`
- **WHEN** the lease pass runs
- **THEN** core SHALL NOT lease it any group, and SHALL revoke any assignment
  it holds
- **AND** the agent SHALL run those groups on its local ticker and the legacy
  path

#### Scenario: Push from a core that predates carried checks
- **WHEN** an agent that executes from carried checks receives a push with slots
  and `lease_version` 1
- **THEN** it SHALL refuse the push with a `SweepLeaseAck` error
- **AND** the group SHALL run on the agent's local ticker only when no valid
  installed lease covers the group

#### Scenario: Batch claims checks its slot did not sign
- **WHEN** EventWriter receives a leased sweep batch whose `tested_checks`
  digest differs from the slot's signed `check_set_sha256`
- **THEN** core SHALL reject the batch with `sweep_check_set_mismatch` before
  any domain write
- **AND** SHALL write no ledger row, batch coordinate or domain row for it
- **AND** SHALL NOT redeliver or quarantine it
- **AND** SHALL leave the slot's state unchanged

## MODIFIED Requirements

### Requirement: Sweep Job Execution Tracking
The system SHALL track scan execution, durable delivery, database projection,
MTR projection, and reconciliation as distinct states. Accurate totals SHALL be
derived from unique authoritative target/mode observations and the immutable
execution plan, not from transport delivery attempts or scanner completion
alone.

#### Scenario: Scanner reports assignment-attempt completion
- **GIVEN** an agent has finished probing its assigned range
- **WHEN** its terminal event is committed
- **THEN** the execution SHALL record scanner completion, duration, cumulative
  counts, and terminal batch sequence for that attempt
- **AND** SHALL remain delivery-pending, projection-pending, partial, or
  MTR-pending until required durable evidence reconciles

#### Scenario: Agent reports sweep completion
- **GIVEN** an agent completing a sweep job
- **WHEN** the sweep finishes
- **THEN** core SHALL record scanner completion, duration, and cumulative (not
  per-batch delta) counts for the assignment attempt, as described in "Scanner
  reports assignment-attempt completion"
- **AND** the execution SHALL NOT be recorded as reconciled complete until the
  conditions in "Execution becomes reconciled complete" hold

#### Scenario: Active scan progress updates
- **GIVEN** an in-progress sweep execution
- **WHEN** bounded progress/watermark events are ingested
- **THEN** core SHALL expose unique scanner, durable-delivery, and projection
  progress without incrementing totals on redelivery
- **AND** the Active Scans UI SHALL distinguish those stages and missing ranges

#### Scenario: Long-lived execution emits bounded microbatches
- **GIVEN** an execution remains active across many collection windows
- **WHEN** bounded result and progress microbatches are committed
- **THEN** execution tracking SHALL reconcile each independent sequence range
  without requiring the execution to close
- **AND** scanner, delivery, projection, and MTR state SHALL NOT depend on a
  run-wide accumulated payload

#### Scenario: Reachability is projected before MTR
- **GIVEN** ICMP/TCP observations are queryable but expected correlated MTR
  traces are not all terminally projected
- **WHEN** execution state is displayed
- **THEN** reachability MAY be shown as available
- **AND** MTR SHALL show pending/missing/failed/quarantined counts
- **AND** the execution SHALL NOT claim full reconciliation

#### Scenario: Execution becomes reconciled complete
- **WHEN** every authoritative plan range and assignment attempt is terminal,
  all declared batch ranges have committed, and every expected MTR trace is
  projected or explicitly terminally failed
- **THEN** the execution SHALL record reconciled completion and exact unique
  totals

#### Scenario: Execution retains attribution context
- **GIVEN** a completed sweep execution
- **WHEN** its results are inspected
- **THEN** the execution SHALL identify the sweep group, the agent that ran it,
  and the config version in force
- **AND** each host result belonging to it SHALL carry the requested sweep modes
  alongside the observed per-mode outcome
