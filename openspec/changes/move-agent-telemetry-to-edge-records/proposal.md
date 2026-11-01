# Change: Move agent telemetry onto the durable edge-record pipeline

## Why

USP-01 (`unify-sweep-results-proto`) built a durable, binary producer pipeline: agent spool,
signed edge records, gateway authorization, JetStream PubAck before the agent may reclaim, and an
idempotent EventWriter ledger. On farm01 it has carried leased static sweeps with zero loss and
survived restarts of the gateway, core, NATS and the agent mid-delivery (M3.3).

Every other kind of agent data still travels over `StreamStatus`/`PushStatus`, and most of it can
be lost today:

- Sysmon, SNMP, ICMP checks, MTR, mapper and netprobe discovery, native add-on telemetry and
  plugin signals are drained from in-memory buffers BEFORE the send succeeds.
- The gateway publishes metric sources with Core NATS `pub` and no PubAck.
- The gateway fallback buffer for forwarded results is in memory and drops the oldest entry when
  it holds 100.
- Several producers still ship JSON inside the status envelope.

The legacy agent status path is turned off completely in the next release. Every durable agent
data family therefore moves in this change; nothing stays on a legacy fallback.

## What Changes

- **Two authority models, chosen by who schedules each run.**
  - **Sweep leases (unchanged)** for runs core schedules: leased static sweeps keep their per-run
    signed plans and `SCHEDULED_SWEEP` source authorization exactly as USP-01 shipped them.
  - **Standing output grants** for everything the agent runs from its own config: sysmon, SNMP
    polls, ICMP checks, rperf, MTR checks, plugin runs, add-on telemetry, OTLP relay, flow
    attribution, discovery, mapper jobs, sync runs, inventory producers, and sweeps that are not
    leased (for example `target_query` groups). Core signs one production capability per
    (agent, contract, authority epoch), delivered in the agent config. These records carry no
    source authorization.
- **One typed output contract per (data family, scheduling model)**, carrying an existing
  protobuf where one exists. JSON producers get a typed batch message first; the registry never
  admits an untyped status envelope. Every agent-scheduled `MetricBatch`, including metrics of
  unleased sweeps, uses `serviceradar.metrics.batch` with no source authorization. A leased
  sweep's metric batch uses `serviceradar.metrics.scheduled` under its own production capability
  on the sweep lease, with `SCHEDULED_SWEEP`.
- **One agent-side producer sink** that every migrated producer appends to, replacing
  drain-before-send buffers. Admission is acknowledged only after the record is durable in the
  spool; a refusal is retryable backpressure and a drop is counted with its reason.
- **One EventWriter projector per contract**, writing the destination the legacy path writes
  today, so storage, alerting and real-time consumers are unchanged.
- **Durable streams.** The edge-record stream and the streams projectors publish to are
  replicated, because the agent reclaims its spool on PubAck.
- **One cutover release.** A producer leaves the status path only in the release where that
  producer emits edge records and while the agent holds the contract's grant. Each family then
  passes a farm01 parity soak; the next release removes every legacy agent emission and the
  gateway's matching publishers.

## Out of Scope

- RTSP and other live media streams: they are not records.
- Control traffic: hello, config, control stream commands and acks, sweep lease acks,
  certificate renewal, credential grants, KV, artifact transfer.
- Ephemeral latest-wins status summaries (agent health, service status heartbeats, plugin-engine
  counters). Per USP-01 task 2.14 these stay on `GatewayServiceStatus`.
- Changing leased static sweeps, their plans or the frozen record ABI.

## Impact

- Affected specs: `edge-producer-data-plane`.
- Affected code: `go/pkg/agent` producers and buffers, `go/pkg/edge` (sink, validators),
  `go/cmd/agent` sender wiring, core grant, contract and trust modules, the agent config
  generator, EventWriter projectors, Helm contract registry, NATS permissions and stream
  replication, and the agent-gateway publishers removed at cutover.
- Depends on: `unify-sweep-results-proto`, which stays the change of record for the shared
  transport.
