# Change: Move agent telemetry onto the durable edge-record pipeline

## Why

USP-01 (`unify-sweep-results-proto`) built a durable, binary producer pipeline:
agent spool, signed edge records, gateway authorization, JetStream PubAck before
the agent may reclaim, and an idempotent EventWriter ledger. On farm01 it has
carried leased static sweeps for 48 hours with zero loss and survived restarts of
the gateway, core, NATS, and the agent mid-delivery (M3.3).

Every other kind of agent data still travels over `StreamStatus`/`PushStatus`,
and most of it can be lost today:

- Sysmon, SNMP, ICMP checks, MTR, mapper and netprobe discovery, native add-on
  telemetry, and plugin signals are drained from their in-memory buffers BEFORE
  the send succeeds. A failed send loses them.
- The gateway publishes metric sources with Core NATS `pub` and no PubAck, so a
  send the agent saw succeed can still be lost between the gateway and JetStream.
- The gateway fallback buffer for forwarded results is in memory, holds 100
  entries, and drops the oldest when full.
- Several producers still ship JSON inside the status envelope.

The pipeline was always meant to be shared. The USP-01 backlog (tasks 2.10-2.14)
names the producer sink, Wasm, native add-on and integration adapters, but they
were deferred to prove the transport on one producer first. That proof is done.

## What Changes

- Add one typed output contract per agent data family. Each carries an EXISTING
  protobuf as its payload where one exists (`metric.v1.MetricBatch`,
  `addon.v1.TelemetryBatch`, `addon.v1.OtlpRelayFrame`,
  `netprobe.v1.FlowAttributionEventBatch`, `edge.v1.MtrTraceBatchV1`). JSON-only
  producers get a typed batch contract before they move.
- Add two core-signed grant models, both expressible in the frozen record ABI with
  no ABI change:
  - **Check leases** for producers core schedules (MTR, ICMP checks, SNMP polls,
    plugin runs, sync runs, mapper jobs): a production capability plus a
    `SCHEDULED_CHECK` or `INTEGRATION_RUN` source authorization, mirroring sweep
    leases. Sweep executions, including the metric batches a sweep lease
    produces, keep `SCHEDULED_SWEEP` under the existing sweep lease.
  - **Standing output grants** for passive producers (sysmon, add-on telemetry,
    OTLP relay, flow attribution, netprobe discovery, workload identity): a
    renewable production capability per (agent, contract) with no source
    authorization, fenced by an authority epoch.
- Add one agent-side producer sink that every migrated producer appends to,
  replacing drain-before-send buffers. Admission is acknowledged only after the
  record is fsynced to the spool.
- Add one EventWriter projector per contract. Each projector writes the same
  destination the legacy path writes today (`timeseries_metrics`, `mtr_traces`,
  OTel/log processors, flow attribution in StarRocks, inventory ingestors), inside
  the existing ledger transaction so redelivery changes nothing.
- Soak producers one family at a time behind a per-agent opt-in, with one path
  per producer at a time (never both). The next release removes legacy agent
  status-path emission and the gateway's matching publishers together, after
  every runnable sweep group has a signed sweep lease. There is no long-lived
  per-family legacy.
- Move sweep groups that use a `target_query` in a final phase, before that
  cutover. Core resolves the query at lease time to individual host addresses,
  which the plan builder can always represent, and freezes that set into a signed
  scheduled plan per execution under the existing sweep lease machinery and
  `SCHEDULED_SWEEP`. When the resolved set changes, core re-plans. A set that
  exceeds plan limits is split across executions or ranges, and every host is
  placed in a signed plan. The group's sweep results and sweep metric batch move
  together once that lease exists. A target the plan builder cannot represent,
  such as an IPv6 prefix wider than /65 (`:target_too_wide`), is refused at sweep
  group configuration with an operator-visible validation error. An existing
  group of that kind is reported as not runnable and does not run on the legacy
  path.

## Out of Scope

- RTSP and other live media streams: they are not records.
- Control traffic: hello, config, control stream commands and acks, sweep lease
  acks, certificate renewal, credential grants, KV, artifact transfer.
- Ephemeral latest-wins status summaries (agent health, service status signature
  heartbeats, plugin-engine counters). Per USP-01 task 2.14 these stay on
  `GatewayServiceStatus`.

## Impact

- Affected specs: `edge-producer-data-plane` (new contract, grant, sink and
  migration requirements).
- Affected code: `go/pkg/agent` push loops and buffers, `go/pkg/edge` (sink,
  contracts), `go/cmd/agent` sender wiring, agent-gateway contract registry and
  authorization, core issuer/lease/grant modules, EventWriter projectors, Helm
  contract registry values.
- Depends on: `unify-sweep-results-proto` (pipeline, spool, sender, gateway relay,
  ledger), which stays the runtime change of record for the shared transport.
