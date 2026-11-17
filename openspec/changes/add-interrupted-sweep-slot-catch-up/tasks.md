## 0. Approval

- [ ] 0.1 The user answers the open questions in `design.md`, and the proposal
      is approved before any implementation starts.
- [ ] 0.2 Load the `test-audit` skill before writing any test in sections 3
      to 6.

## 1. Schema

- [ ] 1.1 Add a migration on `platform.sweep_execution_slots`:
      - `interrupted_at timestamptz NULL`;
      - `catch_up_of uuid NULL` referencing `sweep_execution_slots(id)`;
      - a partial unique index on `catch_up_of WHERE catch_up_of IS NOT NULL`.
- [ ] 1.2 Add both attributes to `ServiceRadar.SweepJobs.SweepExecutionSlot`,
      with these actions:
      - `:record_interruption`, which sets `interrupted_at`;
      - `:schedule_catch_up`, which is `:schedule` plus `catch_up_of`.

      Keep the `unique_assignment_slot` identity unchanged.

## 2. Wire

- [ ] 2.1 `proto/monitoring.proto`: add a `SweepLeaseSlotInterruption` message
      with these fields:
      - `sweep_group_id`;
      - `lease_id`;
      - `execution_id`;
      - `process_started_at_unix_nano`.

      Add it to `ControlStreamRequest` as oneof tag 9, then regenerate the Go
      and Elixir bindings.
- [ ] 2.2 The agent advertises `sweep_lease_interruptions:v1`
      (`push_loop_capabilities.go`).

## 3. Agent

- [ ] 3.1 When `sweepLeaseStore` loads, snapshot the executed entries that
      have an open collection window as the inherited set. Entries claimed
      later by this process are excluded.
- [ ] 3.2 On every control-stream connect, send one
      `SweepLeaseSlotInterruption` for each inherited entry whose window is
      still open. Follow the existing refusal re-send path.
- [ ] 3.3 Add tests:
      - a restart with a claimed open-window slot reports it on every connect
        until the window closes;
      - a slot claimed by the current process is never reported;
      - without the capability, nothing is sent.

## 4. Gateway

- [ ] 4.1 `control_stream_session.ex`: forward `sweep_lease_slot_interruption`
      to core only when the session's hello advertised
      `sweep_lease_interruptions:v1`. Drop it otherwise.
- [ ] 4.2 `ConfigSyncForwarder.record_sweep_lease_slot_interruption/2` and
      `AgentGatewaySync.record_sweep_lease_slot_interruption/2`. A failed core
      call is logged; the agent re-sends on its next connect.
- [ ] 4.3 Add tests for the capability gate, and for decoding the new oneof
      on an older gateway.

## 5. Core: record the interruption

- [ ] 5.1 Add `ExecutionSlots.record_interruption/2`. It sets
      `interrupted_at` only when all of these hold:
      - the slot belongs to the reporting agent, in the named group and lease;
      - the assignment is active at the slot's epoch;
      - the slot is `scheduled`, its window is open, and `catch_up_of` is
        null;
      - `interrupted_at` is still null.

      It returns how many slots moved (0 or 1).
- [ ] 5.2 Add tests for every scenario of the requirement "Agents report
      leased slots a restart interrupted".

## 6. Core: mint and keep catch-up slots

- [ ] 6.1 Add a catch-up planner module under `ServiceRadar.SweepJobs`, with
      these functions:
      - list the assignment's candidate parents (Decision 6);
      - compute the unreported cover as a range difference of the parent plan
        and the parent execution's `SweepHostResult` IPs (Decision 3);
      - estimate the pace and apply the time-fit test (Decision 5);
      - build the plan with `SweepPlan.build/2`.
- [ ] 6.2 In `LeasePass.plan_agent/4`, mint catch-ups in the agent's planning
      transaction, under the delivery lock, with
      `ExecutionSlots.schedule_catch_up`. Add a `catch_ups` count to the pass
      summary and its log line.
- [ ] 6.3 Change `LeasePass.sync_slots/4` to split catch-up slots from
      schedule slots:
      - keep or drop catch-ups by Decision 7;
      - exclude them from `fill/6`'s present set.
- [ ] 6.4 Confirm, with a test, that a minted catch-up reaches the agent in
      the full push triggered by `undelivered_behind?/2`, and that the
      push leaves the parent untouched.
- [ ] 6.5 Add tests for every scenario of the requirements "Core re-runs an
      interrupted slot's unreported hosts in one catch-up slot", "Catch-up
      slots are bounded" and "The lease pass keeps a catch-up slot only while
      its parent's plan is current". Include:
      - an end-to-end projection of catch-up batches through
        `SweepProjection`;
      - the supersede of the parent execution;
      - `LeaseMisses` marking an undelivered catch-up missed.

## 7. Docs and validation

- [ ] 7.1 Document interruption reports and catch-up slots in
      `docs/docs/durable-edge-records.md`, next to the sweep lease
      capabilities.
- [ ] 7.2 Run `openspec validate add-interrupted-sweep-slot-catch-up --strict`.
