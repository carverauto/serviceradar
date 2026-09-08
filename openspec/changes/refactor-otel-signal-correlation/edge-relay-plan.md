# Edge OTLP relay — implementation plan (tasks 10.2-10.5)

Produced 2026-06-11 from a read-only design study of the existing add-on /
agent / gateway / core data paths. Summary of findings and the agreed plan;
the header convention below is the SHARED contract with task 7.6.

## Findings

- The native add-on framework already has add-on→agent telemetry:
  `AddonService.StreamTelemetry` (proto/agent/addon/v1/addon.proto), gated by
  capability `native-telemetry:v1`, supported by rust/addon-sdk. BUT it is
  one-way into a lossy in-memory queue (go/pkg/agent/addon_telemetry.go,
  1024-deep, drop-on-overflow, drained by the 30s push loop) — cannot satisfy
  the spec's "buffered telemetry SHALL be delivered after reconnect".
- Netprobe's UDS frame socket is a pre-framework carve-out; NOT the pattern.
- Agent→gateway transport: `AgentGatewayService.StreamStatus` with
  GatewayServiceStatus envelopes (6 MiB status budget, 16 MiB chunk caps).
- Gateway stamps identity from the agent's mTLS cert (CN
  <component_id>.<partition_id>.serviceradar); cert-derived partition is
  authoritative. Gateway's stream_status currently ALWAYS acks received:true
  even when forwarding fails — fine for lossy status, fatal for a relay.
- Core StatusHandler already decodes TelemetryBatch for addon:/plugin:
  sources and republishes via ServiceRadar.NATS.Connection.publish/3
  (headers supported).

## Decisions

- D-a New acked bidi RPC on AddonService (capability `otlp-relay:v1`):
  `rpc RelayOtlp(stream OtlpRelayAck) returns (stream OtlpRelayFrame)` with
  persistent monotonic relay_id + ack watermark.
- D-b Reuse TelemetryBatch/TelemetryRecord with new payload kinds
  OTLP_TRACES=3, OTLP_LOGS=4, OTLP_METRICS=5 (+ OTLP_DERIVED_METRIC=6);
  payload = one encoded Export*ServiceRequest chunk, chunked ONCE at the
  edge with the existing 900 KiB chunker → 1 record = 1 NATS message.
- D-c Agent reuses StreamStatus with Source="otlp-relay" on a dedicated
  event-driven pump (flush <=100ms; bounded in-flight window), NOT the 30s
  push tick. Ack to the add-on only after gateway success.
- D-d Honest failure semantics for this source: gateway forwards
  synchronously and raises on failure (no false acks); durability owner is
  add-on spool until ack, then NATS.
- D-e Attribution headers stamped in core StatusHandler from the gateway's
  authenticated view: `Sr-Agent-Id`, `Sr-Partition`,
  `Sr-Ingest-Identity: agent:<agent_id>` (7.6 token path uses the same
  header with `token:<name>`). Standard subjects: otel.traces.raw /
  logs.otel / otel.metrics.raw / otel.metrics.derived.
- D-f Edge OTLP clients get OK once durably spooled; oldest-first eviction
  with per-signal counters (carried upstream via TelemetryCounters).

## Steps

0. Wire contract: addon.proto (+ vendored rust/addon-sdk copy, lockstep),
   regen Go/Elixir/Rust stubs, capability constant, SDK seams
   (Addon::relay_otlp default UNIMPLEMENTED).
1. rust/otel src/agent_forward/: AgentForwardOutput (TelemetryOutput impl)
   + segment spool (8 MiB segments, max_bytes default 256 MiB, watermark
   file fsync on rotation/ack-advance, eviction counters); [output]
   backend = jetstream|agent|otlp config.
2. rust/otel-addon crate (bin) implementing addon_sdk::Addon (Info/
   Configure/Health/relay_otlp) + addons/otel-collector/addon.yaml.
3. go/pkg/agent/addon_otlp_relay.go: relay pump (bounded window 64 frames /
   8 MiB, per-frame GatewayServiceStatus, ack on success, backoff retry,
   prometheus counters).
4. Gateway/core: status_processor sync-ack for otlp-relay; gateway raises
   on forward failure; StatusHandler otlp-relay branch republishing with
   Sr-* headers; counters surfaced.
5. Self-telemetry convention: agent injects OTEL_EXPORTER_OTLP_ENDPOINT=
   http://127.0.0.1:<port> (+PROTOCOL=grpc) into add-on/plugin subprocess
   env when the collector add-on is healthy; agent's own logger OTel config
   gains "auto" mode; collector add-on never self-exports through itself.

Ordering: 0 first; then parallel tracks A=(1->2 rust), B=(3 go), C=(4
elixir); 5 after 2. Risks: message caps (enforce <=900 KiB invariant in
pump), at-least-once duplicates (event_id carried for future dedup), Gnat
pub has no JetStream ack (flagged follow-up), add-on lifecycle teardown.
