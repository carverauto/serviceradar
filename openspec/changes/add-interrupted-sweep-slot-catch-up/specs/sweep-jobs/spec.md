# sweep-jobs Delta

## ADDED Requirements

### Requirement: Agents report leased slots a restart interrupted
An agent that advertises the control-stream capability `sweep_lease_interruptions:v1` SHALL report every leased slot it claimed in an earlier process whose collection window is still open, and SHALL NOT report any other slot.

At startup the agent SHALL take the executed entries its sweep lease store loads with an open collection window as the interrupted set, because a new process never resumes a claimed slot. On every control-stream connect, the agent SHALL send one `SweepLeaseSlotInterruption` for each slot in that set whose window is still open. The message names the sweep group, the lease id and the execution id. The agent SHALL NOT report a slot this process claimed. It SHALL NOT report a slot whose window has closed. It SHALL NOT need an acknowledgement.

The gateway SHALL forward the report to core only from a session whose hello advertised the capability. Core SHALL record the report as the slot's `interrupted_at` only when all of these hold:

- the slot belongs to the reporting agent, in the named group and lease;
- the slot's assignment is active at the slot's `authority_epoch`;
- the slot is `scheduled`, its collection window is open, and it is not itself a catch-up slot;
- the slot has no `interrupted_at` yet.

Any other report SHALL change nothing.

#### Scenario: Restart mid-slot is reported
- **GIVEN** an agent advertising `sweep_lease_interruptions:v1` claimed slot
  S, whose window ends at 11:00, and had spooled some of S's hosts
- **WHEN** the agent restarts at 10:20 and reconnects at 10:21
- **THEN** the agent SHALL send a `SweepLeaseSlotInterruption` for S
- **AND** core SHALL set S's `interrupted_at`
- **AND** the agent SHALL NOT run S again

#### Scenario: Re-sent report changes nothing
- **GIVEN** core already recorded S's `interrupted_at`
- **WHEN** the agent reconnects again before 11:00 and re-sends the report
- **THEN** core SHALL leave S unchanged

#### Scenario: Slot claimed by the current process is not reported
- **GIVEN** the agent claimed slot T after its last start
- **WHEN** the agent reconnects to a restarted gateway while T is still
  running
- **THEN** the agent SHALL NOT report T

#### Scenario: Stale or foreign report is ignored
- **WHEN** a report names a slot that is `refused`, `dropped`, missed, already
  past its window, a catch-up slot, under a superseded epoch or lease, or
  another agent's slot
- **THEN** core SHALL record nothing

#### Scenario: Agent without the capability
- **GIVEN** an agent that does not advertise `sweep_lease_interruptions:v1`
- **WHEN** it restarts mid-slot and reconnects
- **THEN** it SHALL send no interruption report
- **AND** the gateway SHALL forward none
- **AND** the slot SHALL behave exactly as before this change

### Requirement: Core re-runs an interrupted slot's plan in one catch-up slot
For each slot with `interrupted_at` that passes the catch-up bounds, core SHALL mint exactly one non-dropped catch-up slot that re-runs the parent's full plan. Minting SHALL happen in the shared planning of the agent's slots, so whichever runs first after `interrupted_at` is recorded mints it: the periodic lease pass or a session refresh. In this capability, "lease pass" means either planning.

The catch-up slot SHALL have:

- a new `execution_id` and a new plan id;
- `catch_up_of` set to the parent slot's id;
- the parent's assignment, network scope, `authority_epoch`, `lease_id` and `check_set_sha256`;
- a `slot_start` later than the mint time, so the next lease push still carries it as unrun;
- the parent's `collection_expires`.

Its plan SHALL carry the same range CIDR list as the parent and as every other slot of the lease, so the existing production-capability signing, which binds one range list per lease push, applies unchanged. Core SHALL mint a catch-up only when at least one of the parent plan's addresses has no `SweepHostResult` under the parent `execution_id`.

Core SHALL deliver the catch-up through the existing lease push. Its results SHALL project as an ordinary execution whose `hosts_total` is the plan's target count, under the unchanged projection fencing. Each result SHALL carry its own observation time. A host that already reported in the parent SHALL be probed again, and its newest observation SHALL win.

#### Scenario: Partial parent re-runs its full plan
- **GIVEN** an interrupted parent whose plan is `192.0.2.0/24`
- **AND** the parent execution has results for `192.0.2.0` through
  `192.0.2.95`
- **WHEN** the lease pass mints its catch-up
- **THEN** the catch-up plan SHALL hold `192.0.2.0/24`, 256 targets, the
  same CIDR list as the lease's other slots
- **AND** the catch-up SHALL carry a new `execution_id` and plan id, with
  `catch_up_of` naming the parent
- **AND** the lease push carrying it with the next scheduled slot SHALL be
  signed as one production scope

#### Scenario: Parent with no committed result re-runs its whole plan
- **GIVEN** an interrupted parent with no `SweepHostResult`
- **WHEN** the catch-up passes the bounds
- **THEN** its plan SHALL target every address of the parent plan

#### Scenario: Complete parent gets no catch-up
- **GIVEN** an interrupted parent with a `SweepHostResult` for every planned
  address
- **WHEN** the lease pass runs
- **THEN** core SHALL mint no catch-up

#### Scenario: Catch-up results project as their own execution
- **WHEN** the agent runs the catch-up and its batches commit
- **THEN** each batch SHALL pass the same epoch, lease, plan and slot checks
  as any leased batch
- **AND** the catch-up execution SHALL complete when every catch-up target
  has a result
- **AND** each host's last sweep time and availability ledger entry SHALL
  take the catch-up result's own observation time

#### Scenario: Catch-up window never overlaps the next slot
- **GIVEN** a parent window that ends at 11:00, where the next scheduled slot
  starts
- **WHEN** a catch-up is minted at 10:25
- **THEN** its `slot_start` SHALL be after 10:25
- **AND** its `collection_expires` SHALL be 11:00

### Requirement: Catch-up slots are bounded
Core SHALL mint a catch-up only when every one of the following holds, and SHALL otherwise mint none:

- The parent has `interrupted_at`, is `scheduled`, and is not itself a catch-up.
- No non-dropped catch-up already names the parent.
- The parent execution, if any, is not `cancelled`.
- The assignment is active, and its current epoch and lease id equal the parent's.
- The agent's current check set for the group equals the parent's.
- The group's planned CIDRs equal the parent plan's CIDRs.
- At least one of the parent plan's addresses has no `SweepHostResult` under the parent execution.
- The estimated scan time fits before the parent's `collection_expires`.

The scan time estimate SHALL be the parent plan's `total_target_count` times a pace. The pace SHALL be the `duration_ms` divided by `hosts_total` of the most recent completed execution of the same group by the same agent. With no such execution there is no pace, and core SHALL mint no catch-up; the hosts wait for the next scheduled slot. Core SHALL NOT use a fixed cutoff or a pace derived from the window length.

A catch-up SHALL never be the parent of another catch-up. A catch-up that runs past its window SHALL end like any slot cut off by its window.

#### Scenario: Next slot too close
- **GIVEN** the last completed execution scanned 1,000 hosts in 20 minutes
- **AND** an interrupted parent whose plan has 1,000 targets, 400 of them
  unreported, with 15 minutes of window left at minting
- **WHEN** the lease pass runs
- **THEN** core SHALL mint no catch-up, because the 20-minute estimate for
  the full plan does not fit

#### Scenario: Catch-up fits
- **GIVEN** the same pace
- **AND** a 1,000-target parent plan with 27 minutes of the parent window
  left at minting
- **WHEN** the lease pass runs
- **THEN** core SHALL mint the catch-up

#### Scenario: No completed execution means no catch-up
- **GIVEN** an interrupted parent of a group with no completed execution by
  the agent
- **WHEN** the lease pass runs
- **THEN** core SHALL mint no catch-up

#### Scenario: Interrupted catch-up is not caught up
- **GIVEN** an agent restarts while running a catch-up slot
- **WHEN** it reports that catch-up as interrupted
- **THEN** core SHALL record nothing and SHALL mint no further catch-up

#### Scenario: Refused, dropped, missed or cancelled parent
- **WHEN** the parent is `refused`, `dropped`, `missed_offline` or
  `missed_exhausted`, or its execution is `cancelled`
- **THEN** core SHALL mint no catch-up

#### Scenario: Operator changed the group before minting
- **GIVEN** an interrupted parent
- **AND** the operator changed the group's targets or checks, or the
  assignment's epoch was bumped, before the next lease pass
- **WHEN** the lease pass runs
- **THEN** core SHALL mint no catch-up

#### Scenario: At most one non-dropped catch-up per parent
- **WHEN** two lease passes, or a pass and a retry, evaluate the same parent
- **THEN** at most one slot that is not `dropped` SHALL have `catch_up_of`
  equal to that parent

### Requirement: The lease pass keeps a catch-up slot only while its parent's plan is current
The lease pass SHALL keep an unstarted catch-up slot only while it still satisfies all of these against its parent, and SHALL drop it otherwise:

- the assignment's current epoch and lease id;
- the network scope;
- the agent's current check set;
- the group's planned CIDRs equal the parent plan's CIDRs.

The pass SHALL NOT drop a catch-up for falling off the schedule grid. It SHALL NOT count a catch-up as a scheduled slot when it fills the horizon. Revoking the assignment, deleting or disabling the group, or making it ineligible SHALL drop an unstarted catch-up like any unrun slot. A catch-up that has started SHALL be fenced like any started slot.

On each lease pass, a catch-up whose `slot_start` has passed and for which no `SweepLeaseAck` with `installed = true` exists for any push that carried it SHALL be dropped, and the pass SHALL then mint a new catch-up for the same parent if the catch-up bounds still hold. The pass SHALL NOT use `delivered_at` for this, because a push stamps it before the send. The pass SHALL NOT drop by this rule a catch-up whose install was acknowledged. An installed catch-up that never commits SHALL be marked missed like any slot, and SHALL NOT reopen or change its parent.

#### Scenario: Unchanged group keeps the catch-up
- **GIVEN** an unstarted catch-up whose parent plan matches the group's
  current plan
- **WHEN** the lease pass runs
- **THEN** the catch-up SHALL stay `scheduled`
- **AND** the pass SHALL mint the schedule's slots as if the catch-up were
  absent

#### Scenario: Group targets change after minting
- **GIVEN** an unstarted catch-up
- **WHEN** the operator changes the group's targets and the lease pass runs
- **THEN** the pass SHALL drop the catch-up
- **AND** the next full push SHALL remove it from the agent

#### Scenario: Group deleted
- **GIVEN** an unstarted catch-up
- **WHEN** the group is deleted or disabled
- **THEN** the catch-up SHALL be dropped with the assignment's other unrun
  slots

#### Scenario: Uninstalled catch-up is re-minted
- **GIVEN** a catch-up minted at 10:25 with `slot_start` 10:25:05 and
  `collection_expires` 11:00
- **AND** the push carrying it stamped `delivered_at` and then failed because
  the agent was disconnected, so no installed ack exists for it
- **WHEN** the agent reconnects at 10:26 and the session refresh that
  connect starts plans the agent, and the plan still fits before 11:00
- **THEN** the refresh SHALL drop that catch-up
- **AND** SHALL mint a new catch-up for the same parent and push it to the
  agent
- **AND** once the agent acknowledges installing the replacement, the 10:30
  lease pass SHALL leave it `scheduled` and mint no other catch-up

#### Scenario: Installed catch-up is not re-minted
- **GIVEN** a catch-up whose push the agent acknowledged with
  `installed = true`
- **WHEN** a lease pass runs after its `slot_start`
- **THEN** the pass SHALL NOT drop it or mint another catch-up for the parent

#### Scenario: Uninstalled catch-up no longer fits
- **GIVEN** a catch-up with no installed ack whose `slot_start` has passed
- **WHEN** the lease pass runs and the plan no longer fits before the
  parent's `collection_expires`
- **THEN** the pass SHALL drop that catch-up and mint none
