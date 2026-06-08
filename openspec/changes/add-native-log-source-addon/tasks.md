## 1. Contract and SDK
- [x] 1.1 Add a server-streaming telemetry RPC to `AddonService` in `proto/agent/addon/v1/addon.proto` with a `TelemetryBatch` message: source type/instance, observed time, event time, stable event identity/idempotency key, payload-kind enum (`ocsf_event`, `otel_log`, …), payload bytes, source metadata, and producer counters (received/filtered/emitted/dropped + queue depth). Keep it in `serviceradar.agent.addon.v1` (additive, not v2).
- [x] 1.2 Define the capability string (`native-telemetry:v1`) and update Go (`go/pkg/addon`) + Rust (`rust/addon-sdk`) SDK `Info` paths so add-ons advertise it; agent calls the telemetry RPC only for advertising add-ons.
- [x] 1.3 Extend the Go native add-on client/manager (`go/pkg/agent/addon`) to open and drain the telemetry stream from supervised, capability-advertising add-ons.
- [x] 1.4 Extend `rust/addon-sdk` with an ergonomic telemetry emitter API (batch builder, idempotency-key helper, counters).
- [x] 1.5 Update Bazel `BUILD` files for the regenerated `addon.proto` (Go + Rust/prost) so `bazel test` stays green.
- [x] 1.6 Add compatibility tests: an add-on implementing only Info/Configure/Health runs unchanged and the agent reports no telemetry capability for it.

## 2. Agent and Gateway Routing
- [x] 2.1 Add agent-side batching, bounded queues, size limits, backpressure handling, and cumulative + delta drop counters for add-on telemetry (template: `go/pkg/agent/push_loop_flow_attribution.go`).
- [x] 2.2 Forward batches via `AgentGatewayService.StreamStatus` using `GatewayServiceStatus.source="addon:<addon_id>"` with the `TelemetryBatch` serialized into `bytes message`; reserve the `addon:` source prefix. Do NOT add a new gateway RPC.
- [x] 2.3 Add core routing for the `addon:*` source discriminator, preserving payload kind and event identity/idempotency keys.
- [x] 2.4 Add tests proving tenant/partition/gateway/agent identity is taken from the gateway-authenticated mTLS envelope (`<component_id>.<partition_id>.serviceradar`), not from add-on- or client-supplied fields.

## 3. PowerDNS Rust Add-On
- [x] 3.1 Vendor `dnsmessage.proto` from the canonical `PowerDNS/dnsmessage` repo (MIT), pinned to a recorded git tag/commit; generate Rust with prost-build (proto2 → `Option<T>` scalars). NOT from `pdns/pdns`.
- [x] 3.2 Implement the Rust native add-on with a configurable localhost TCP listener and PowerDNS framing: read `[uint16 big-endian length][PBDNSMessage]`, cap N at 65535 (no 4-byte framestream form).
- [x] 3.3 Decode query/response + RPZ fields: `question.{qName,qType,qClass}`, `id`, `response.{rcode,rrs[]}`, `appliedPolicy`, `appliedPolicyType`, `appliedPolicyTrigger`, `appliedPolicyHit`, `appliedPolicyKind`, `from`/`fromPort`/`to`/`toPort` (raw 4/16 NBO bytes → IpAddr), `timeSec`/`timeUsec`, `response.queryTimeSec`/`queryTimeUsec`.
- [x] 3.4 Default filtering to RPZ/policy hits only; require explicit config for full DNS query/response logging.
- [x] 3.5 Map to OCSF DNS Activity (`class_uid=4003`, `category_uid=4`, `type_uid` 400301/400302, OCSF 1.8.0) per the design.md mapping: RPZ → Security Control `action_id`/`disposition_id` + `firewall_rule`; do NOT use `unmapped` for RPZ. Special-case `rcode=65536` → `rcode_id=99`/Failure. Stamp OCSF schema version.
- [x] 3.6 Emit via the generic telemetry contract (payload kind `ocsf_event`) with a stable per-event idempotency key (e.g. derived from server identity + DNS id + timestamps).
- [x] 3.7 Expose Health degradation + counters for listener errors, decode failures, queue pressure, and dropped records.

## 4. OCSF Ingestion (reuse existing path)
- [x] 4.1 Register the `pdns.ocsf` NATS subject in `elixir/serviceradar_core/.../event_writer/config.ex` (convention `{domain}.{type}`, like `trivy.report.>`) and add a DNS RPZ processor modeled on `processors/trivy_reports.ex`; reuse `OCSF.class_dns_activity` (`ocsf.ex:53`).
- [x] 4.2 Add the `pdns.ocsf` → `ocsf_events` subject/table mapping in `go/pkg/consumers/db-event-writer`; rely on the existing `InsertOCSFEvents` `ON CONFLICT (id, time) DO NOTHING` for idempotency.
- [x] 4.3 Ensure emitted events carry the required/recommended OCSF fields (`id`, `time`, `class_uid`, `category_uid`, `type_uid`, `activity_id`, `severity_id`) and preserve PowerDNS source extras in `unmapped`/`enrichments` for re-projection — without storing unbounded raw payloads by default.
- [x] 4.4 Expose DNS events to SRQL (v1: `events` filtered by `class_uid=4003`; confirm whether a dedicated `dns_events` catalog entity is added now or at the D7 escalation).
- [x] 4.5 Document the D7 escalation trigger and target (generated/indexed columns + DNS CAGG on `ocsf_events`, or a dedicated `ocsf_dns_activity` hypertable per the `ocsf_network_activity` pattern) so the upgrade path is unambiguous if profiling demands it.

## 5. Packaging and Configuration
- [x] 5.1 Add the PowerDNS add-on `addon.yaml` (`pushed-artifact` + `agent-sidecar`) and config schema for listener address, source name, RPZ-only vs full-logging mode, queue/batch limits, and event mapping mode.
- [x] 5.2 Document Recursor emitter config: `protobufServer()` / `logging.protobuf_servers` (5.1.0+) with `logResponses=true`, `taggedOnly=true` (RPZ-only volume control), and `setProtobufMasks()` for client-IP anonymization; note `outgoingProtobufServer` is not needed.
- [x] 5.3 Document why OTEL collector exposure is not required for DNS hosts (agent path carries auth + partition).

## 6. Verification
- [x] 6.1 Unit tests for PowerDNS protobuf decoding fixtures (incl. all `appliedPolicyKind` values) and RPZ → OCSF 4003 mapping (action_id/disposition_id/firewall_rule).
- [x] 6.2 Integration tests for add-on → agent → `StreamStatus`/`source=addon:powerdns` routing with bounded batches and drop-counter reporting.
- [x] 6.3 db-event-writer persistence tests for DNS OCSF events incl. duplicate-batch dedup via `ON CONFLICT (id, time)`.
- [x] 6.4 Validate OpenSpec with `openspec validate add-native-log-source-addon --strict`.
