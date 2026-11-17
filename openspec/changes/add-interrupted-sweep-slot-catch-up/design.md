# Design: catch-up slots for interrupted leased sweeps

## Context

A leased sweep group runs from pre-minted execution slots
(`platform.sweep_execution_slots`, `ServiceRadar.SweepJobs.SweepExecutionSlot`).
Each slot is one execution: `id` is the `execution_id`, the row holds the
collection window `[slot_start, collection_expires]`, the fence it was planned
under (`authority_epoch`, `lease_id`) and the plan it binds (`plan_sha256`,
`plan_header`, `plan_pages`). For interval and cron schedules alike the window
of one slot ends exactly where the next slot starts (`LeaseSchedule.slots/3`).

### Slot states today

| State | Set by | When |
| --- | --- | --- |
| `scheduled` | `ExecutionSlots.schedule/4`, `schedule_many/3` (lease pass `fill/6`) | minted for a schedule slot in the agent's horizon |
| `dropped` | `ExecutionSlots.drop/2`, `drop_unrun/3` | an unstarted slot no longer matches its group, or the assignment was revoked |
| `missed_offline` / `missed_exhausted` | `LeaseMisses.mark/2`, end of every lease pass | window closed 300 s ago and **no** `sweep_group_executions` row exists for the slot |
| `refused` | `ExecutionSlots.refuse/2`, from the agent's `SweepLeaseSlotRefusal` | the agent will not run the slot; terminal |

A slot with even one committed batch has an execution row, so `LeaseMisses`
never marks it: a cut-off slot stays `scheduled`. `SweepProjection` accepts a
batch for a slot in `scheduled` or a missed state, and reopens a missed slot
to `scheduled` (`reopen_missed_slot/2`), because a record is judged by its
event time. It refuses `dropped` and `refused`.

### Fencing on every batch

`SweepProjection.project/3` checks the following before it writes:

- `current_assignment/2`: the assignment is `active` at the record's
  `authority_epoch` and `run_shard`;
- `slot_matches/3`: the slot state, sweep group, agent, network scope,
  assignment, `lease_id` (the record's `run_id`), `plan_id`, `plan_sha256` and
  `authority_epoch`;
- `authorized_plan/3`: the plan header and range digests.

Batches are keyed by `(network_scope_id, execution_id, execution_shard,
assignment_epoch, batch_sequence)` in `platform.edge_sweep_batch_slots`. The
same coordinate with different bytes is a conflict
(`Projectors.SweepObservation`).

### How core learns what was reported

Every projected host writes a `SweepHostResult`, upserted per execution and IP.
`finish_if_complete/4` counts those rows against the plan's
`total_target_count`. So core can always tell, per execution, which plan
addresses have a result.

### What the agent does

- `sweepLeaseExecutor.runSlot` runs a due slot from its own clock. It is
  connected or not, and it runs the slots of all groups one at a time.
- Before the first spool append, `sweepEdgeProducer.appendClaimed` persists
  the slot as executed (`sweepLeaseStore.MarkExecuted`, with the slot's
  `collection_expires`). A spool admission refusal releases that claim.
- A slot with no admitted record can therefore be retried in its window,
  across restarts. A slot with an admitted record is never run again: "an
  interrupted run that already admitted a record stays incomplete".
- When the scan reaches its deadline (collection expiry less the flush
  reserve, #6731/#6736), the producer spools every completed host window
  first.

### Leases on the wire

Leases are pushed as `SweepLeaseV1` window replacements over the control
stream. Three capabilities gate them:

- `sweep_lease_v1`: the agent receives leases (`LeaseDelivery`,
  `AgentCommandBus`);
- `sweep_lease_plan_checks:v1`: core leases only to such agents
  (`LeaseAgents`);
- `sweep_lease_hello_digests:v1`: the gateway forwards the hello's installed
  digests only from such a hello.

The 5-minute `LeasePassWorker` and the session refresh on every control hello
(`LeaseRefresh`, `LeasePass.refresh_agent/4`) both re-plan and push under the
per-agent delivery lock. A full push carries every unrun slot (`slot_start >
now`). It goes out, among other triggers, when an unrun slot with no
`delivered_at` sits behind the delivery cursor (`undelivered_behind?/2`).

### Why hosts go `unknown`

A host is marked unavailable only on explicit failed observations
(`host_available?/1`, the consecutive-down threshold of 2). After one interval
of silence from the deciding agent, `PinSilenceWorker` back-dates the ledger
entry and re-resolves. With no other evidence the resolver returns `unknown` /
`no_evidence`, and the projection keeps `is_available` at its last value. The
ledger TTL is `2 x interval + 5 min` (`availability_ledger_ttl/1`).

Take a host last observed at offset `o` into slot k-1, and let slot k be cut
off at offset `c < o`. The host's next result is at offset `o` of slot k+1.
It is `unknown` for about one interval.

## Goals / Non-Goals

Goals:

- Re-run, promptly and inside that slot's own window, a leased slot that an
  agent restart kept from reporting every planned host.
- Keep core the authority over what runs: execution ids, plans, signatures and
  fencing stay core-minted.
- Bound it so that a re-run never repeats without end, never overlaps the next
  slot, and never outlives an operator change.
- Leave agents without the new capability exactly as they are.

Non-Goals:

- An agent-side result journal, or late admission of records.
- Re-running a slot cut off by its own window closing (Decision 8).
- Run errors inside a live process, and operator cancels (Decision 1).
- UI that shows a catch-up execution next to its parent (open question 5).

## Decisions

### Decision 1: Core decides; the agent reports the one fact only it has

Core is the authority. It validates the report, judges completeness from what
committed, applies every bound, and mints, signs and pushes the catch-up slot.

The agent supplies only one fact: *this process will not continue execution X*.
The agent learns it at startup. Every executed entry that `sweepLeaseStore`
loads with an open window was claimed by an earlier process, and a new process
never resumes a claimed slot. The agent snapshots those entries at load and
sends one `SweepLeaseSlotInterruption` per entry on every control-stream
connect while its window is open, exactly as refusals are re-sent. No new
agent persistence is needed.

The agent cannot tell from its store whether such a slot finished, because
`MarkExecuted` records claim and completion the same way. So it reports every
inherited claim, and core decides completeness from `SweepHostResult`. A
completed slot reported this way is a no-op.

The scope is restarts only. A run that ends early inside a live process does
so on an operator cancel, a revoked or replaced slot, or a producer error such
as a duplicate result or an address outside the plan. In each of those cases
a re-run is wrong or would fail the same way.

Alternatives considered:

- **Core alone, when the window closes.** Core can see that an execution
  holds fewer results than its plan, but only once the window has closed and
  the 300 s grace has passed. By then the next slot has started, so there is
  no time left to re-run anything (Decision 8).
- **Core alone, on reconnect.** A control-stream reconnect does not prove a
  restart: a gateway restart reconnects an agent whose scan is still running.
  The hello carries no process identity, and adding one still would not tell
  core which executions the old process owned.
- **The agent re-runs on its own.** The agent cannot mint an execution id,
  build a plan, or sign source authorizations, and it must not reuse the
  slot's batch coordinates (Decision 2). That would break the leased-slot
  model.
- **A result journal.** Rejected by the user and restated here. Records the
  scan completed are already durable in the spool (#6731/#6736), so a journal
  adds nothing for them. It cannot recover a host that was never scanned, and
  that is the whole problem.

### Decision 2: A catch-up is a new execution, not a continuation

The re-run is a new slot with its own `execution_id`, plan and plan digest.
It has the same assignment, epoch, lease id, network scope, check set and
ranges as its parent. Every fencing check in `slot_matches/3` and `current_assignment/2`
then applies unchanged, and the projection, batch coordinates and completion
counting need no new cases.

Alternatives considered:

- **Continue the parent execution.** A restarted process does not know the
  last `batch_sequence` the old one spooled. Starting again at 1 collides with
  committed coordinates and different bytes, which
  `upsert_sweep_batch_slot` refuses as a conflict. Fixing that needs an
  attempt discriminator in the frozen batch identity. That is an ABI change
  across Go, Elixir and the gate vectors, made to save one execution row.
- **Re-push the parent slot.** The agent skips it as executed, and running it
  again would re-scan every host under coordinates already used.

### Decision 3: The catch-up re-runs the parent's full plan

The catch-up plan has the same CIDR list as the parent and as every other slot
of the lease, with the parent's check set. `SweepPlan.build/2` builds it with a
fresh plan id, so it has its own `plan_id` and `plan_sha256`; its ranges are
the parent's.

The reason is lease signing. `LeaseCapabilities.production_capability/5`
signs one production scope per lease push, and `one_lease/2` requires every
slot in the push to carry the same range CIDR list (`:mixed_lease` otherwise).
A full push carries every unrun slot of the assignment, so a catch-up holding
a subset of the ranges would make the whole push fail, taking the next
schedule slot's horizon update with it. With the parent's ranges the
catch-up rides the existing push and signing is unchanged.

Completeness is still judged per address. Core mints a catch-up only when at
least one planned address has no `SweepHostResult` under the parent
`execution_id`. A parent whose every planned address has a result gets none.
A host window the parent buffered but never published has no result, so it
counts as unreported, which is correct.

Trade-off:

- Hosts that already reported in the parent are probed again. That is
  harmless: the second result is a duplicate observation of the same host, and
  the ledger and device views keep the newest event time.
- The time-fit test (Decision 5) uses the full plan's target count, so a
  catch-up fits less often late in the window than one sized to the unreported
  hosts would.

Example, synthetic: the parent plan is `192.0.2.0/24` (256 targets). The
parent execution has results for `192.0.2.0` through `192.0.2.95`. The
catch-up plan is `192.0.2.0/24`, 256 targets, under a new plan id.

Alternatives considered:

- **Re-run only the unreported addresses (option B).** The catch-up plan
  would be the exact CIDR cover of the unreported addresses, for example
  `192.0.2.96/27` and `192.0.2.128/25` above. A push then carries slots with
  different range lists, so the lease scope would have to bind the group's
  planned CIDRs and each slot would only be required to be contained in them.
  Rejected because it changes production-capability signing and the
  `lease_scope_sha256/3` contract, which this change keeps as is.
- **Re-run every range with a missing host.** Same signing problem as option
  B whenever it is not the whole plan.

### Decision 4: When and how a catch-up is minted

The report is recorded at once
(`ExecutionSlots.record_interruption/2` sets `interrupted_at`). Minting, and
the drop-and-re-mint step below, live in the shared `plan_agent/4` ->
`sync_slots/4` path, so whichever planning of the agent runs first after
`interrupted_at` is recorded performs them: the 5-minute `LeasePassWorker`
run or a session refresh (`LeasePass.refresh_agent/4`). There is no mode
gating. `plan_agent/4` mints under the delivery lock and the same transaction
that plans the agent's other slots, and `deliver/4` pushes it after commit.
The report arrives after the hello, so the refresh that the same connect
starts usually runs before it is recorded. Minting therefore usually falls to
the next pass, at most five minutes later, or to a later refresh.

The delay is useful. Records the old process spooled drain after the
reconnect, so by the next planning most of them have committed. The completeness
judged at mint time is then close to the truth (open question 1).

The catch-up slot looks like this:

- `slot_start`: the mint time plus a short delivery lead (an implementation
  constant of seconds). The slot must still be unrun (`slot_start > now`) when
  the push built right after commit carries it.
- `collection_expires`: the parent's `collection_expires`. The catch-up window
  lies inside the parent's window, so it can never overlap the next scheduled
  slot, whose start is that same instant.
- `id`: `ExecutionSlots.mint_id(slot_start)`.
- `catch_up_of`: the parent slot id.
- Epoch, lease id, network scope, check set: the assignment's current values,
  which the bounds require to equal the parent's.

The push path needs nothing new. The catch-up has no `delivered_at` and starts
behind the cursor, so `undelivered_behind?/2` makes the pass send a full push.
The push window starts at `now`. It carries the catch-up and the rest of the
horizon, and leaves the parent untouched, because the parent started before
the window. The agent installs the catch-up as one more slot of the lease.

If the push fails, the catch-up never reaches the agent, and once its
`slot_start` passes it is no longer unrun, so no later push carries it.
`delivered_at` cannot tell this apart from a push that arrived:
`LeaseDelivery` records the push and stamps every carried slot's
`delivered_at` before `AgentCommandBus.push_sweep_lease` runs, and a send to a
disconnected agent fails after that stamp. The rule therefore keys on install
acknowledgement. When core stores a `SweepLeaseAck` with `installed = true`
for a push, it stamps `install_acked_at` on the catch-up slots that push
carried; the delivery row keeps only the latest push, so the slot has to hold
this itself. The shared `delivered_at` stamp is unchanged.

The next planning of the agent, pass or refresh, drops a catch-up that has
no `install_acked_at` and whose `slot_start` has passed, then mints a fresh
one for the same parent if Decision 5 and Decision 6 still hold. Example: the
10:25 pass mints a catch-up with `slot_start` 10:25:05 while the agent is
disconnected, and the push stamps `delivered_at` and then fails. The agent
reconnects at 10:26, and the session refresh that connect starts drops that
row and, if the plan still fits before the parent's window closes, mints
another and pushes it. Once the agent acknowledges installing it, the 10:30
pass leaves it alone. A send that returned `:ok` but
was never installed is recovered the same way. A catch-up the agent did
install is never dropped by this rule, so a run in progress is not cut off.
An install whose ack was lost is open question 6.

### Decision 5: The time-fit cutoff is derived, not hardcoded

Let `N` be the parent plan's `total_target_count`, which is also the
catch-up's (Decision 3). Core estimates the catch-up's scan time as
`N x pace`:

- `pace` is `duration_ms / hosts_total` of the most recent `completed`
  `SweepGroupExecution` of the same sweep group by the same agent.
- With no such execution there is no pace, and core mints no catch-up. A
  group's first sweep that is cut off simply waits for its next interval.
  Dividing the parent window by `N` is not used: that estimate is exactly one
  window, which can never fit after the parent has started.

Core mints the catch-up only if `slot_start + N x pace <=
collection_expires`. The parent window ends at the next scheduled slot, so
"the next slot is close" is exactly "the re-run would not finish before it".
No other constant is involved.

A catch-up that still runs long is cut off by its window like any slot. The
flush reserve spools what it completed, and the catch-up is never caught up
itself (Decision 6).

Example, synthetic. The interval is 1 h, the plan has 1,000 targets, and the
last completed execution took 20 min for 1,000 hosts (1.2 s per host). The
agent restarts 30 min into a slot with 400 hosts unreported, and the next pass
mints at minute 33. The estimate is 20 min, which ends at minute 53 of a
window that ends at minute 60, so core mints the catch-up. Had the restart
come at minute 45, the 20 min would not fit, and the next slot covers those
hosts.

### Decision 6: Bounds

Core mints a catch-up for a parent only when all of these hold:

1. The parent has `interrupted_at` set, is `scheduled`, has a window that
   fits by Decision 5, and has `catch_up_of` null, so it is not itself a
   catch-up.
2. No non-dropped slot has `catch_up_of` equal to the parent's id. A partial
   unique index enforces this.
3. The parent execution, if one exists, is not `cancelled`. An operator
   cancel withdraws the run.
4. The assignment is `active`, and its current epoch and lease id equal the
   parent's.
5. The agent's current check set for the group equals the parent's
   `check_set_sha256`, and the group's planned CIDRs equal the parent plan's
   CIDRs. This is the test `sync_slots/4` already applies to unrun slots, so
   the catch-up never runs targets or checks the operator has since changed.
6. At least one planned address has no `SweepHostResult` under the parent
   execution (Decision 3).

Why this terminates:

- A `refused`, `dropped` or missed parent is excluded by rule 1. A missed
  slot has, by definition, a closed window.
- Rules 1 and 2 give each scheduled slot at most one live extra execution,
  and a catch-up can never become a parent. A catch-up is replaced only when
  its install was never acknowledged and its start has passed (Decision 4),
  so the agent runs at most one of them outside the lost-ack case (open
  question 6); replacements stop when the fit test fails, which
  it must before the parent's window closes.
- The windows of one assignment's slots do not overlap, and a catch-up's
  window lies inside its parent's. So an agent holds at most one open
  catch-up per group at a time.

Agent limits need no new machinery:

- The catch-up runs through the same executor, run lock and spool admission
  (`appendWithBackpressure`) as any slot.
- At the measured pace it occupies the executor for no longer than one
  uninterrupted run of the plan, and it must finish before the next slot.

### Decision 7: The lease pass keeps a catch-up only while its parent's plan is current

`sync_slots/4` compares each unrun slot with the schedule's desired slot at
the same start and with the group's planned CIDRs. As written, it would drop
every catch-up, whose start is off the schedule grid. Catch-up slots
(`catch_up_of` not null) are therefore split out:

- A catch-up is **kept** when it still satisfies Decision 6, rules 3 to 5,
  against its parent. That covers epoch, lease id, scope, check set, and the
  parent plan's CIDRs equal to the current planned CIDRs.
- Otherwise it is **dropped** through `ExecutionSlots.drop/2`, so only an
  unstarted one is dropped.
- A catch-up with no `install_acked_at` whose `slot_start` has passed is
  **dropped and re-minted** by Decision 4. `drop/2` only drops a slot whose
  start is still ahead, so this needs its own drop, limited to such
  catch-up rows.
- It never counts as a present desired slot in `fill/6`.

A group that is deleted, disabled or made ineligible revokes the assignment,
and `drop_unrun/3` drops an unstarted catch-up with every other slot. A
catch-up already running when that happens is fenced by `current_assignment/2`
like any slot.

### Decision 8: A slot cut off by its own window is not re-run

The window of a slot ends at the next slot's start. A scan cut off by the
window closing therefore leaves no time before the next slot, and the next
slot scans every planned host again from the beginning. The Decision 5 rule
yields no catch-up here, and that is the right outcome:

- After a late start (for example, the agent came back near the end of the
  window and retried an unclaimed slot), the next slot is the re-run.
- A plan that does not fit its interval is a sizing problem. A catch-up
  cannot add scan time that does not exist.

The agent does not report such a slot, because the restart rule in Decision 1
does not cover it. Open question 2 asks whether the next slot should scan
those hosts first.

### Decision 9: Gated on `sweep_lease_interruptions:v1`

- The agent sends the report only when it advertises the capability.
- The gateway forwards `sweep_lease_slot_interruption` to core only from a
  session whose hello advertised it, the rule the hello digests use.
- Core records an interruption only through that path.

Mixed versions:

| Agent | Gateway | Core | Behaviour |
| --- | --- | --- | --- |
| old | any | any | no report, no catch-up: today's behaviour |
| new | old | any | the unknown oneof decodes to no payload and is ignored; no catch-up |
| new | new | old | the forward fails and is logged; the agent re-sends on its next connect; no catch-up |
| new | new | new | catch-ups as designed |

A catch-up slot is an ordinary `SweepLeaseSlotV1`. An agent that is
downgraded after reporting still runs it correctly.

## Interactions

- **`PinSilenceWorker`.** The catch-up result lands about `r + p + q` after
  the cut-off, where:
  - `r` is restart and reconnect time;
  - `p` is the wait for the next planning of the agent, at most 5 min (the
    next lease pass), plus the delivery lead;
  - `q` is the host's position in the catch-up scan, which is its position
    `o` in the full plan.

  A host the cut-off missed sits at an offset `o` past the cut-off offset
  `c`. Its silence expires at offset `o` of the cut-off slot, one interval
  after its last result, and the catch-up reaches it at about
  `c + r + p + o`. So it is `unknown` for about `c + r + p` instead of about
  one interval. Re-running the full plan is what costs the `c` term
  (Decision 3). `PinSilenceWorker` only handles `<n><s|m|h|d>` intervals, so
  cron groups are unaffected.
- **Availability ledger TTL** (`2 x interval + 5 min`). A catch-up observation
  is a normal ledger write with `checked_at` taken from the result's
  `last_sweep_time`, the observation time. It always lands inside the TTL.
  The ledger upsert keeps the newest `checked_at`, so event time decides the
  order.
- **Down detection.** A catch-up failure is a real observation, and counts
  toward the consecutive-down threshold of 2. A host that is really down is
  marked down one observation sooner than it would be now. The
  available-wins window is unchanged.
- **Completeness and progress.**
  - The catch-up is its own `SweepGroupExecution`, with `hosts_total = N`. It
    completes when all N report, through the unchanged `finish_if_complete/4`.
  - When the catch-up's first batch creates that execution, the ingestor
    supersedes the still-running parent (`status = failed`, "superseded by new
    execution"). That is today's behaviour for a newer run, and an accurate
    end for a run that will not finish.
  - Late parent records still store their host rows, but do not bump the
    closed parent's progress.
  - The relation between the two is the slot's `catch_up_of`.
  - `SweepServiceState` and the group's `last_run_at` follow the catch-up like
    any execution.
- **Device "last sweep time".** It comes from each result's
  `last_sweep_time`, which is the catch-up's own observation time. Every host
  of the plan shows the fresher time once the catch-up reaches it.
- **`LeaseMisses`.** These are unchanged:
  - An installed catch-up that never commits is marked missed after its
    window. One with no installed ack is dropped by the lease pass first.
  - A parent that committed stays `scheduled`.
  - A catch-up never marks or reopens its parent.
- **`ExecutionReaper`.** This is unchanged. It reaps an interrupted parent the
  catch-up did not supersede.
- **Lease delivery cost.** Each catch-up causes one full push, which re-signs
  the agent's unrun horizon for that group (see
  `fix-sweep-lease-reissue-stall` and `set-based-sweep-lease-issuance`). There
  is at most one per agent restart per group, which is far rarer than the
  session re-issue every reconnect already performs.

## Risks / Trade-offs

- **Reported hosts are re-scanned.** The catch-up re-runs the full plan
  (Decision 3), so every host the parent already reported is probed again and
  gets a duplicate result, which is harmless. The newest event time wins.
- **A catch-up fits less often late in the window.** The fit test uses the
  full plan's target count, not the unreported count.
- **A parent whose missing results are still in the spool gets a catch-up.**
  Completeness is judged at mint time. See open question 1.
- **Up to five minutes' delay.** This comes from minting in the next planning
  of the agent, usually the periodic pass.
  It is acceptable for the hourly and longer intervals this targets, and for
  short intervals the Decision 5 fit test usually declines anyway. See open
  question 4.
- **The pace estimate can be wrong.** If the network got slower, the catch-up
  is cut off by its window, which is the same outcome as no catch-up for the
  hosts it did not reach. If it got faster, a catch-up that would have fit may
  be skipped, and the next slot covers those hosts.

## Migration Plan

1. Add the migration on `platform.sweep_execution_slots`:
   - `interrupted_at timestamptz NULL`;
   - `catch_up_of uuid NULL REFERENCES platform.sweep_execution_slots(id)`;
   - `install_acked_at timestamptz NULL`, set only on catch-up slots;
   - a partial unique index on `catch_up_of WHERE catch_up_of IS NOT NULL
     AND state <> 'dropped'`.

   The migration is additive, and existing rows get nulls.
2. Ship core and gateway before or with agents. Ordering is not required for
   safety (Decision 9).
3. Rollback: agents stop advertising the capability, and core ignores the
   columns. A catch-up already minted runs or is marked missed like any slot.

## Open Questions

1. **Spool-drain race (not designed in).**
   - Failure mode: after a restart with a large unresolved spool backlog, the
     next pass sees a parent as incomplete only because its last records are
     still waiting to drain, and mints a catch-up that re-probes the plan.
   - Likelihood: low. A healthy spool drains in seconds after reconnect, and
     the pass runs up to five minutes later.
   - Cost to prevent: gate minting on the hello's `edge_record_spool` showing
     no unresolved records, or recompute the missing set at push time. This
     adds a dependency on spool health reporting to lease planning.

   Is the cost of one extra full-plan run acceptable?
2. **Window-close cut-offs.** Should the next scheduled slot scan the previous
   slot's unreported hosts first? That would help a slot cut off by its own
   window (Decision 8). It changes plan ordering, which is canonical and
   digest-bound, so it is a larger change. Proposed: no.
3. **In-process early ends.** Should a run that ends early in a live process
   also be reported? The causes are the agent's own run errors after
   admission. Today they are a cancel, a revoked or replaced slot, or a
   producer error, and none of them is helped by a re-run. Proposed: no.
4. **Faster minting.** Minting at the next planning costs up to five
   minutes. The alternative mints right after recording the report, by
   running the planner for that one assignment. It saves up to five minutes,
   but it widens the race in question 1 and adds a planning trigger on the
   report. Proposed: keep the existing pass and refresh triggers.
5. **UI.** Should the execution views show a catch-up next to its parent, or
   give the parent a reason more specific than "superseded by new execution"?
   Not needed for correctness. Proposed: separate follow-up if wanted.
6. **Lost install ack (not designed in).**
   - Failure mode: the agent installs the catch-up but its `SweepLeaseAck` is
     lost. Once `slot_start` passes, core drops the catch-up and re-mints it
     (Decision 4). The projection refuses the first run's batches because
     that slot is `dropped`, and the re-minted slot scans the plan again. The
     result is a duplicate scan whose first results are refused; the hosts
     still get results from the re-minted run if it fits.
   - Likelihood: rare. It needs an ack lost after a successful install, on a
     catch-up, within the few seconds before its `slot_start`.
   - Cost to prevent: wait for the next ack, or an agent signal that it holds
     the slot, before dropping. That adds a second acknowledgement state to
     lease delivery for one rare case.

   Is the duplicate scan acceptable?
