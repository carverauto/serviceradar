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

## 2. Metrics batch (`serviceradar.metrics.batch`)

- [ ] 2.1 Contract and payload rules for `metric.v1.MetricBatch`.
- [ ] 2.2 Agent: sysmon, SNMP, ICMP, MTR metrics and rperf append through the sink
  when opted in, and stop the legacy emission for those producers. Sweep metric
  batches for a sweep that already has a lease append under `SCHEDULED_SWEEP`.
  A `target_query` group's sweep metric batch stays with its sweep results until
  that group's lease exists, then both move together under `SCHEDULED_SWEEP`.
- [ ] 2.3 EventWriter projector writing the existing metrics destination inside the
  ledger transaction.
- [ ] 2.4 farm01 parity soak against a control agent.

## 3. MTR traces

- [ ] 3.1 Check leases for MTR checks; agent emits `MtrTraceBatchV1`.
- [ ] 3.2 Projector into `mtr_traces` and hops; parity soak.

## 4. Flow attribution and OTLP relay

- [ ] 4.1 Contracts for `FlowAttributionEventBatch` and `OtlpRelayFrame`.
- [ ] 4.2 Producers and projectors; parity soak.

## 5. Plugin and add-on telemetry

- [ ] 5.1 `TelemetryBatch` contract; plugin signals and native add-on telemetry
  through the sink.
- [ ] 5.2 Typed Wasm plugin result batch; producer and projector.
- [ ] 5.3 Parity soak.

## 6. Inventory producers

- [ ] 6.1 Typed batch contracts for mapper, netprobe discovery, sync pages,
  workload identity, endpoint inventory, bumblebee and k8s endpoints.
- [ ] 6.2 Producers and projectors; parity soak.

## 7. Query-resolved sweeps

- [ ] 7.1 Approve the resolution model: core resolves `target_query` at lease
  time to individual host addresses, freezes that set into a signed scheduled
  plan per execution under the existing sweep lease and `SCHEDULED_SWEEP`, and
  re-plans when the resolved set changes. A set that exceeds plan limits is
  split across executions or ranges.
- [ ] 7.2 Build that signed plan from the resolved host addresses, splitting
  across executions or ranges when the set exceeds plan limits.
- [ ] 7.3 Issue the frozen plan through the existing sweep lease scheduler. The
  group's sweep results and sweep metric batch move together once the lease
  exists, both under `SCHEDULED_SWEEP`.
- [ ] 7.4 Refuse a target the plan builder cannot represent, including an IPv6
  prefix wider than /65 (`:target_too_wide`), at sweep group configuration with
  an operator-visible validation error. Report an existing group of that kind as
  not runnable. Do not send it on the legacy path.
- [ ] 7.5 farm01 parity soak against a control agent.

## 8. Closure

- [ ] 8.1 In the next release, after every per-family parity soak and after every
  runnable sweep group has a signed sweep lease, remove legacy agent status-path
  emission and the gateway's matching publishers together.
- [ ] 8.2 Confirm no durable agent data remains on `StreamStatus`/`PushStatus`;
  only control traffic and ephemeral status summaries stay there.
