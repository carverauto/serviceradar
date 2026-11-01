# Tasks: Move agent telemetry onto the durable edge-record pipeline

## 1. Shared foundations

- [ ] 1.1 Standing output grants: core signs, renews and revokes one production
  capability per (agent, contract, authority epoch); delivery on the control
  stream; gateway trust snapshot carries the epochs.
- [ ] 1.2 Check leases: generalize the sweep lease scheduler, issuer and carrier to
  scheduled checks (`SCHEDULED_CHECK`) and sync runs (`INTEGRATION_RUN`), reusing
  missed-run marking and epoch fencing.
- [ ] 1.3 Agent producer sink: grant validation, event identity, spool append with
  durable acknowledgement, retryable backpressure, counted drops.
- [ ] 1.4 Wire spool admission backpressure (USP-01 M3.2) and byte-fair lane
  interleaving (USP-01 2.7) before any high-volume family moves.
- [ ] 1.5 Contract registry: add each contract to the signed registry and Helm
  values, off by default.

## 2. Metrics batch (`serviceradar.metrics.batch`)

- [ ] 2.1 Contract and payload rules for `metric.v1.MetricBatch`.
- [ ] 2.2 Agent: sysmon, SNMP, ICMP, MTR metrics, sweep metrics and rperf append
  through the sink when opted in, and stop the legacy emission.
- [ ] 2.3 EventWriter projector writing the existing metrics destination inside the
  ledger transaction.
- [ ] 2.4 farm01 parity soak against a control agent; then remove the legacy
  emission and the gateway metric publishers in a gated release.

## 3. MTR traces

- [ ] 3.1 Check leases for MTR checks; agent emits `MtrTraceBatchV1`.
- [ ] 3.2 Projector into `mtr_traces` and hops; parity soak; legacy removal.

## 4. Flow attribution and OTLP relay

- [ ] 4.1 Contracts for `FlowAttributionEventBatch` and `OtlpRelayFrame`.
- [ ] 4.2 Producers and projectors; parity soak; legacy removal.

## 5. Plugin and add-on telemetry

- [ ] 5.1 `TelemetryBatch` contract; plugin signals and native add-on telemetry
  through the sink.
- [ ] 5.2 Typed Wasm plugin result batch; producer and projector.
- [ ] 5.3 Parity soak; legacy removal.

## 6. Inventory producers

- [ ] 6.1 Typed batch contracts for mapper, netprobe discovery, sync pages,
  workload identity, endpoint inventory, bumblebee and k8s endpoints.
- [ ] 6.2 Producers and projectors; parity soak; legacy removal.

## 7. Closure

- [ ] 7.1 Confirm no durable agent data remains on `StreamStatus`/`PushStatus`;
  only control traffic and ephemeral status summaries stay there.
