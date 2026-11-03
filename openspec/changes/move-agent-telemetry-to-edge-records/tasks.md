# Tasks: Move agent telemetry onto the durable edge-record pipeline

## 1. Shared foundations

- [ ] 1.1 Standing output grants: core issues, renews and revokes one capability per (agent,
  contract, epoch); delivered in the agent config; gateway trust snapshot carries the fences.
  Records under a grant carry no source authorization. Lease-signed `SweepObservationBatchV1`
  records stay on `serviceradar.sweep.observation` with the lease capability and
  `SCHEDULED_SWEEP`, and are not grant records.
- [ ] 1.2 Agent producer sink: shared record builder, spool append with durable acknowledgement,
  retryable backpressure, counted drops.
- [ ] 1.3 Spool admission backpressure (USP-01 M3.2) and byte-fair lane interleaving (USP-01 2.7)
  before any high-volume family moves.
  PARTIAL: the high/low-water pause (M3.2) and byte-fair admission across producer flows
  at the agent spool (2.7) are in; the rest of USP-01 2.7 stays open.
- [ ] 1.4 Replicate `TELEMETRY_EDGE_RECORD_V1_BULK` and the projector destination streams;
  reconciliation raises the replica count of an existing stream.
- [ ] 1.5 EventWriter dispatch by output contract through a projector registry and behaviour;
  no per-contract clause in the processor.
- [ ] 1.6 One generic republish projector, configured per contract, for destinations that are
  JetStream subjects (metrics, logs, OTel).
- [ ] 1.7 Core issues standing grants for every registry entry marked agent-scheduled instead of
  naming contracts in code.

## 2. Metrics

- [ ] 2.1 Sysmon on `serviceradar.metrics.batch`: grant, agent producer, projector that
  republishes to the existing `metrics.>` subject, core NATS publish permission. Sysmon stops
  its status-path emission in this release while the agent holds the grant. SNMP, ICMP, rperf,
  MTR, the periodic sweep summary, and unleased sweep-results chunk batches keep the status path.
- [ ] 2.2 SNMP, ICMP, rperf and MTR metrics on the same contract. Each stops its own status-path
  emission only in the release that moves it, and only while the agent holds the grant.
- [ ] 2.3 Periodic sweep summary `MetricBatch` on `serviceradar.metrics.batch`, with no source
  authorization. It stays the status-interval sample of the single newest group, leased or not.
  Do not add a per-group interval emitter. This producer stops its status-path emission only in
  this release, and only while the agent holds the grant. A leased execution still emits no
  metric batch of its own.
- [ ] 2.4 farm01 parity soak against a control agent.

## 3. MTR traces

- [ ] 3.1 Agent-scheduled MTR trace contract reusing the frozen trace messages without a
  per-run source join. Every MTR trace, including a trace from a sweep group whose modes include
  mtr, moves here under the standing grant, with no sweep-lease dependency. Producer and projector
  into `mtr_traces`; parity soak.

## 4. Flow attribution and OTLP relay

- [ ] 4.1 Contracts for `FlowAttributionEventBatch` and `OtlpRelayFrame`; producers and
  projectors; parity soak.

## 5. Plugin and add-on telemetry

- [ ] 5.1 `TelemetryBatch` contract for plugin signals and native add-on telemetry. Routing keys
  off the SDK's closed TelemetryBatch payload kinds (`serviceradar_metrics`, `ocsf_event`,
  `otel_log`). Manifest `signal_schemas` describe only event and log schemas (`ocsf_event`,
  `otel_log`). One projector routes each closed payload kind to its existing destination.
  Plugins and add-ons never get contracts of their own. A new payload kind is an SDK and core
  change.
- [ ] 5.2 Typed Wasm plugin result batch; producer and projector.
- [ ] 5.3 Parity soak.

## 6. Unleased sweep results

- [ ] 6.1 Sweep results contract for unleased groups, reusing the frozen host observation
  messages without a plan join; projector into today's sweep and inventory tables. The whole
  `MetricBatch` appended to each of those unleased results chunks moves in this same task onto
  `serviceradar.metrics.batch` with no source authorization, keeping every series it carries:
  `sweep.total_hosts`, `sweep.available_hosts`, `sweep.sequence`, `sweep.port.*`, `sweep.host.*`,
  `sweep.scanner.*`, and `sweep.banner_grab.*`. Define the contract and its payload, ship them,
  and pass the farm01 parity soak before cutover task 8.1.

## 7. Inventory producers

- [x] 7.1 Typed batch contracts for mapper, netprobe discovery, sync pages, workload identity,
  endpoint inventory, bumblebee and k8s endpoints. Mapper, netprobe discovery, and sync pages
  are `proto/edge/v1/json_producer_batches.proto`. Workload identity, endpoint inventory,
  bumblebee, and k8s endpoints are `workload_identity.proto`, `endpoint_inventory.proto`,
  `bumblebee.proto`, and `k8s_endpoints.proto`, with checked-in Go and Elixir bindings.
- [ ] 7.2 Producers and projectors; parity soak.

## 8. Cutover

- [ ] 8.1 One release removes every legacy agent emission and the gateway publishers that serve
  them. It follows task 6.1. It does not remove `GetSweepResults`, the sweep results KV,
  `serviceradar.sweep` on `StreamStatus`, or the gateway sweep publisher until the unleased sweep
  results contract and its payload are defined, shipped, and have passed the farm01 parity soak.
- [ ] 8.2 Confirm no durable agent data remains on `StreamStatus`/`PushStatus`; only control
  traffic and ephemeral status summaries stay there.
