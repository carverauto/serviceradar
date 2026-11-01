# Tasks: Move agent telemetry onto the durable edge-record pipeline

## 1. Shared foundations

- [ ] 1.1 Standing output grants: core issues, renews and revokes one capability per (agent,
  contract, epoch); delivered in the agent config; gateway trust snapshot carries the fences.
- [ ] 1.2 Agent producer sink: shared record builder, spool append with durable acknowledgement,
  retryable backpressure, counted drops.
- [ ] 1.3 Spool admission backpressure (USP-01 M3.2) and byte-fair lane interleaving (USP-01 2.7)
  before any high-volume family moves.
- [ ] 1.4 Replicate `TELEMETRY_EDGE_RECORD_V1_BULK` and the projector destination streams;
  reconciliation raises the replica count of an existing stream.
- [ ] 1.5 EventWriter dispatch by output contract; one projector per contract.

## 2. Metrics

- [ ] 2.1 Sysmon on `serviceradar.metrics.batch`: grant, agent producer, projector that
  republishes to the existing `metrics.>` subject, core NATS publish permission.
- [ ] 2.2 SNMP, ICMP, rperf and MTR metrics on the same contract.
- [ ] 2.3 Leased-sweep metric batches on `serviceradar.metrics.scheduled` under the sweep lease.
- [ ] 2.4 farm01 parity soak against a control agent.

## 3. MTR traces

- [ ] 3.1 Agent-scheduled MTR trace contract reusing the frozen trace messages without a
  per-run source join; producer and projector into `mtr_traces`; parity soak.

## 4. Flow attribution and OTLP relay

- [ ] 4.1 Contracts for `FlowAttributionEventBatch` and `OtlpRelayFrame`; producers and
  projectors; parity soak.

## 5. Plugin and add-on telemetry

- [ ] 5.1 `TelemetryBatch` contract for plugin signals and native add-on telemetry.
- [ ] 5.2 Typed Wasm plugin result batch; producer and projector.
- [ ] 5.3 Parity soak.

## 6. Unleased sweep results

- [ ] 6.1 Sweep results contract for unleased groups, reusing the frozen host observation
  messages without a plan join; projector into today's sweep and inventory tables; parity soak.

## 7. Inventory producers

- [ ] 7.1 Typed batch contracts for mapper, netprobe discovery, sync pages, workload identity,
  endpoint inventory, bumblebee and k8s endpoints.
- [ ] 7.2 Producers and projectors; parity soak.

## 8. Cutover

- [ ] 8.1 One release removes every legacy agent emission and the gateway publishers that serve
  them.
- [ ] 8.2 Confirm no durable agent data remains on `StreamStatus`/`PushStatus`; only control
  traffic and ephemeral status summaries stay there.
