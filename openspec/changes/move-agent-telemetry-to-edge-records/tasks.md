# Tasks: Move agent telemetry onto the durable edge-record pipeline

## 1. Shared foundations

- [ ] 1.1 Standing output grants: core signs, renews and revokes one production
  capability per (agent, contract, authority epoch); delivery on the control
  stream; gateway trust snapshot carries the epochs.
- [ ] 1.2 Check leases: generalize the sweep lease scheduler, issuer and carrier to
  scheduled checks (`SCHEDULED_CHECK`) and sync runs (`INTEGRATION_RUN`), reusing
  missed-run marking and epoch fencing, without retargeting sweep slots. Sweep
  executions stay `EDGE_SOURCE_AUTHORIZATION_KIND_SCHEDULED_SWEEP`.
- [ ] 1.3 Agent producer sink: grant validation, event identity, spool append with
  durable acknowledgement, retryable backpressure, counted drops.
- [ ] 1.4 Wire spool admission backpressure (USP-01 M3.2) and byte-fair lane
  interleaving (USP-01 2.7) before any high-volume family moves.
- [ ] 1.5 Contract registry: add each contract to the signed registry and Helm
  values, off by default.

## 2. Passive metrics (`serviceradar.metrics.batch` v1)

- [ ] 2.1 Contract and payload rules: `metric.v1.MetricBatch`, standing grant, and
  records carry no source authorization. Sysmon and any other passive metric
  producer.
- [ ] 2.2 Agent: those producers append through the sink when opted in, and stop
  the legacy emission.
- [ ] 2.3 EventWriter projector writing the existing metrics destination inside the
  ledger transaction. The lease-run contract in section 3 shares this projector.
- [ ] 2.4 farm01 parity soak against a control agent.

## 3. Lease-run metrics (`serviceradar.metrics.scheduled` v1)

- [ ] 3.1 Contract and payload rules: the same `metric.v1.MetricBatch` payload.
  Records must carry a source authorization: `SCHEDULED_CHECK` for SNMP, ICMP,
  and MTR metrics and for rperf, and `SCHEDULED_SWEEP` for sweep metric batches
  under the sweep lease.
- [ ] 3.2 Agent: SNMP, ICMP, MTR metrics and rperf append through the sink when
  their check lease exists, and stop the legacy emission. Sweep metric batches
  for a sweep that already has a lease append under `SCHEDULED_SWEEP`. A sweep
  group with no lease yet, including a `target_query`, short-interval, mtr-mode,
  or banner-grab group, keeps its sweep metric batch with its sweep results until
  that lease exists, then both move together under `SCHEDULED_SWEEP`.
- [ ] 3.3 Use the section 2 projector and the existing metrics destination.
- [ ] 3.4 farm01 parity soak against a control agent.

## 4. MTR traces

- [ ] 4.1 Check leases for MTR checks, including traces from a sweep group whose
  modes include mtr. The agent emits `MtrTraceBatchV1` when MTR checks move, with
  no dependency on that group's sweep lease. Reachability and port results of
  that sweep stay on the sweep lease.
- [ ] 4.2 Projector into `mtr_traces` and hops; parity soak.

## 5. Flow attribution and OTLP relay

- [ ] 5.1 Contracts for `FlowAttributionEventBatch` and `OtlpRelayFrame`.
- [ ] 5.2 Producers and projectors; parity soak.

## 6. Plugin and add-on telemetry

- [ ] 6.1 `TelemetryBatch` contract; plugin signals and native add-on telemetry
  through the sink.
- [ ] 6.2 Typed Wasm plugin result batch; producer and projector.
- [ ] 6.3 Parity soak.

## 7. Inventory producers

- [ ] 7.1 Typed batch contracts for mapper, netprobe discovery, sync pages,
  workload identity, endpoint inventory, bumblebee and k8s endpoints.
- [ ] 7.2 Producers and projectors; parity soak.

## 8. Query-resolved sweeps

- [ ] 8.1 Approve the resolution model: the signed plan is `SweepCompiler`'s target
  resolution, the same function the compiler uses today (`normalize_target_query`
  partition scoping, where `SRQLQuery.ensure_target/2` prepends `in:devices` only
  when the trimmed query does not already start with `in:`, alias filters,
  per-row non-address drops, static targets),
  signed under the existing sweep lease and `SCHEDULED_SWEEP`. A successful read
  whose targets differ re-plans. A set that exceeds plan limits is split across
  executions or ranges.
- [ ] 8.2 Build that plan by calling `SweepCompiler` target resolution, not a
  second resolver. A failed device read, including a later page error or an
  alias-table error, keeps the last signed plan and does not sign a partial page
  set or a plan that omits aliases. An unparseable query, and a query that parses
  but cannot be translated or cast, contributes no hosts and does not keep the
  last plan; static targets still run.
- [ ] 8.3 Issue the frozen plan through the existing sweep lease scheduler. The
  group's sweep results and sweep metric batch move together once the lease
  exists, both under `SCHEDULED_SWEEP` on `serviceradar.metrics.scheduled` v1.
- [ ] 8.4 Refuse a static target the plan builder cannot represent, including an
  IPv6 prefix wider than /65 (`:target_too_wide`), at sweep group configuration
  with an operator-visible validation error. A CIDR in a query ip column is
  dropped for that row and does not refuse the group. Report an existing group
  with such a static target as not runnable. Do not send it on the legacy path.
- [ ] 8.5 farm01 parity soak against a control agent.

## 9. Lease homes before cutover

- [ ] 9.1 Lower `LeaseSchedule.min_interval_seconds` from 300 to 1 so every
  whole-second interval leases, and so does a cron whose closest fires are at
  least one second apart. State the cost: a one-second group over seven days is
  about 604800 slots, 300 times the five-minute floor.
- [ ] 9.2 A sweep group whose modes include mtr: the sweep lease covers
  reachability and port results under `SCHEDULED_SWEEP`. Traces are
  `MtrTraceBatchV1` under the MTR check lease when MTR checks move (task 4.1),
  with no dependency on that group's sweep lease. SweepPlan no longer refuses
  the group for mtr mode.
- [ ] 9.3 Add an additive banner-results output contract: a new typed payload
  message and a contract registry entry. `EdgeRecordV1` and the frozen payloads
  stay unchanged. Banner results ride under the same sweep lease and
  `SCHEDULED_SWEEP` as the execution they belong to.
- [ ] 9.4 Refuse a static target the plan builder still cannot represent after
  9.1-9.3, at sweep group configuration, with an operator-visible error. A CIDR
  in a query ip column is dropped for that row. Report an existing group with
  such a static target as not runnable. Do not send it on the legacy path.

## 10. Closure

- [ ] 10.1 In the next release, after every per-family parity soak and after every
  runnable sweep group has a signed sweep lease, remove legacy agent status-path
  emission and the gateway's matching publishers together.
- [ ] 10.2 Confirm no durable agent data remains on `StreamStatus`/`PushStatus`;
  only control traffic and ephemeral status summaries stay there.
