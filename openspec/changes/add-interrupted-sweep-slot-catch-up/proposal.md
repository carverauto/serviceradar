# Change: Re-run the hosts a restart cut out of a leased sweep slot

## Why

A leased sweep slot that an agent restart or crash cuts off mid-run is never
resumed. Once the slot has a record in the spool the agent's lease store marks
it executed, and a new process skips it (`sweep_lease_executor.go`, the claim
in `sweep_edge_producer.go`). The hosts the slot never reached have no fresh
result until the next scheduled slot reaches them, up to one interval later.

They are not marked down. A host becomes unavailable only on an explicit failed
observation (`SweepProjection.host_available?/1`). But one interval after their
last result `Inventory.Availability.PinSilenceWorker` expires the deciding
agent's ledger entry, the resolver decides `unknown` with reason
`no_evidence`, and `is_available` keeps its last value. For the hourly and
longer intervals that production uses, those hosts sit in `unknown` for most of
an interval after every agent restart that lands mid-sweep.

PR #6731 and #6736 made a cut-off scan spool every host window it completed and
keep admission waits through the flush reserve, so what was scanned is not
lost. An agent-side result journal was considered and rejected: it cannot
recover hosts that were never scanned. What is missing is a prompt re-run of
the cut-off slot, so the hosts it never reported get a fresh result.

## What Changes

- **Agent report.** An agent advertising the new control-stream capability
  `sweep_lease_interruptions:v1` reports each leased slot it claimed in an
  earlier process whose collection window is still open, as a new
  `SweepLeaseSlotInterruption` control message. It reports on every
  control-stream connect until the window closes, like
  `SweepLeaseSlotRefusal`. The report states one fact that only the agent
  knows: this process will not continue that execution.
- **Core records the report.** Core records it on the slot
  (`interrupted_at`) only for the reporting agent's slot of an active
  assignment, at the assignment's current epoch and lease, in state
  `scheduled`, whose window is still open and which is not itself a catch-up.
  Re-sends change nothing.
- **Core re-runs the interrupted slot's plan in one catch-up slot.** When the
  parent execution lacks a `SweepHostResult` for at least one planned address,
  the first planning of the agent after the report (usually the reconnect
  refresh, otherwise the 5-minute lease pass, through the shared
  `plan_agent/4` path) mints a catch-up slot: a new execution id and a new plan id
  over the parent's full plan, with the same CIDR list as the parent and every
  other slot of the lease, under the parent's check set and the assignment's
  current epoch and lease id. Because the ranges are unchanged, the
  production-capability signing (one range list per lease push) is unchanged.
  Hosts that already reported in the parent are probed again, which is
  harmless. Its collection window starts after minting and ends at the
  parent's `collection_expires`, so it never overlaps the next scheduled slot.
  Core delivers it through the existing full lease push for an undelivered
  slot behind the cursor. `SweepLeaseV1` and the batch identity do not change,
  and the agent runs it like any other slot.
- **Bounds.** Core mints no catch-up when the estimated scan time of the full
  plan does not fit before the parent's window closes. The estimate comes from
  the agent's last completed execution of the group. With no completed
  execution there is no estimate and no catch-up, so a group's first sweep
  waits for its next interval. Core also mints none when:
  - every planned address of the parent already has a result;
  - the parent was refused, dropped or missed, or its execution was cancelled;
  - the parent already has a non-dropped catch-up, or is itself a catch-up;
  - the assignment's epoch, lease, check set or planned targets changed.

  So each scheduled slot has at most one live extra execution, and catch-ups
  never chain.
- **Lease pass bookkeeping.** Every planning of the agent, pass or refresh,
  keeps an unstarted catch-up slot only
  while its parent's plan is still the group's current plan for the agent and
  its parent execution is not cancelled, and drops it otherwise. A catch-up whose `slot_start` has passed with no
  installed `SweepLeaseAck` for any push that carried it is dropped and, if
  the bounds still hold, minted again, so one failed push does not cost the
  re-run. The shared `delivered_at` stamp, set before the send, is not used
  for this. Revoking the
  assignment, or deleting or disabling the group, drops it like any unrun
  slot.
- **Mixed versions.** An agent without `sweep_lease_interruptions:v1` sends no
  report and gets no catch-up, which is today's behaviour. Gateways forward
  the report only from a session whose hello advertised the capability, and an
  older gateway ignores the unknown payload.

Out of scope:

- an agent-side result journal, and late admission of records. Edge records
  stay governed by the existing durable pipeline;
- re-running a slot cut off by its own collection window closing. That window
  ends where the next slot starts, so the next slot is the re-run (design
  Decision 8);
- run errors inside a live process, and operator cancels.

## Impact

- Affected specs: `sweep-jobs` (ADDED requirements only).
- Affected code:
  - `proto/monitoring.proto`: `ControlStreamRequest` oneof tag 9 and the new
    `SweepLeaseSlotInterruption` message.
  - `go/pkg/agent/sweep_lease.go`, `sweep_lease_executor.go`,
    `push_loop_capabilities.go` and the control-stream sender.
  - `elixir/serviceradar_agent_gateway/.../control_stream_session.ex` and
    `config_sync_forwarder.ex`.
  - `ServiceRadar.Edge.AgentGatewaySync`.
  - `ServiceRadar.SweepJobs.ExecutionSlots`, `SweepExecutionSlot`
    (`interrupted_at`, `catch_up_of`, `install_acked_at`), `LeasePass`, and
    `LeaseDelivery.record_ack/3`, which stamps `install_acked_at`.
  - A new catch-up planner module under `ServiceRadar.SweepJobs`.
  - One migration on `platform.sweep_execution_slots`.
- No change to `SweepLeaseV1`, `SweepObservationBatchV1`, the batch coordinate,
  `LeaseCapabilities` production-capability signing, `SweepProjection`
  fencing, `LeaseMisses`, or the availability resolver.
