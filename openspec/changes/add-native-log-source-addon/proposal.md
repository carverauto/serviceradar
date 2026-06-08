# Change: Native log source add-ons (PowerDNS protobuf → OCSF DNS Activity)

## Why
PowerDNS Recursor can stream high-value DNS and RPZ (Response Policy Zone) decision telemetry as its own protobuf wire format, but it does not emit ServiceRadar-native OTEL or OCSF records. Opening the cluster OTEL collector (`rust/otel`, gRPC on `:5317`) to DNS hosts is the wrong trust model: that endpoint has no tenant/partition awareness and would require firewall holes from every DNS VM into the cluster. Those VMs already run `serviceradar-agent`, so telemetry should enter through the authenticated, partition-attested agent path instead.

RPZ policy hits are first-class threat-intelligence signals (a blocked domain is a CTI sighting), so this telemetry must land as queryable OCSF security events, not opaque logs. ServiceRadar also needs this to be a *reusable* native log-source pattern, not a one-off PowerDNS bridge: the native add-on contract (`AddonService` = Info/Configure/Health only today) cannot yet let an add-on produce telemetry at all, so a generic emission contract is the actual prerequisite.

## What Changes
- **Add a generic add-on telemetry contract.** Extend `AddonService` (`proto/agent/addon/v1/addon.proto`) with a new add-on→agent server-streaming RPC carrying bounded, source-agnostic telemetry batches (source kind/instance, event identity, observed/event timestamps, payload kind, encoded payload bytes, producer counters). Add-ons opt in by advertising a capability string (e.g. `native-telemetry:v1`) in the existing `InfoResponse.capabilities`, so legacy Info/Configure/Health-only add-ons keep working untouched.
- **Add the PowerDNS Rust native add-on.** A new `rust/` add-on (go-plugin/AutoMTLS supervised, like `addons/rust-sample-addon`) owns a long-lived localhost TCP listener, frames PowerDNS protobuf messages (2-byte big-endian length prefix), decodes `PBDNSMessage` (proto2) including the RPZ `DNSResponse.appliedPolicy*` fields, and maps selected records into normalized **OCSF DNS Activity (class_uid 4003)** events emitted through the generic contract.
- **Route add-on telemetry through the existing agent path.** The agent drains add-on batches into the already-proven `AgentGatewayService.StreamStatus` path using a `GatewayServiceStatus.source` discriminator (e.g. `addon:powerdns`) — the same mechanism netprobe flow-attribution, sysmon-metrics, plugin-telemetry, and results already use. No new gateway RPC. Core uses gateway-attested partition/agent/gateway identity (from the mTLS CN `<component_id>.<partition_id>.serviceradar`) and treats add-on-supplied identity as source metadata only.
- **Reuse the existing OCSF ingestion path.** Publish OCSF DNS events to a new NATS subject (`pdns.ocsf`, following the `{domain}.{type}` convention used by `trivy.report.>`), consumed by the existing `db-event-writer` Go consumer and written to `ocsf_events` keyed on `class_uid=4003`. Idempotency rides the existing `ON CONFLICT (id, time) DO NOTHING` insert (`go/pkg/db/ocsf_events.go:50`). No direct DB writes from add-on or DNS host.
- **Default to RPZ/policy hits only.** Full DNS query/response logging is explicit opt-in; defaults keep volume bounded with queue/batch limits and drop counters.

## Dependencies and Sequencing
- **`add-agent-feature-sets` (in-flight, 18/45):** defines the `agent-feature-sets` capability this change ADDs to. That capability is not yet archived into `openspec/specs/`, so this change MUST archive **after** `add-agent-feature-sets`. The three telemetry requirements here are additive (no header collision with that change's supervision/isolation requirements) and describe the first telemetry-emitting reference consumer of the framework.
- **`add-native-addon-rust-sdk` (✓ complete):** the go-plugin/AutoMTLS Rust SDK (`rust/addon-sdk`) is the foundation; this change extends it with a telemetry emitter API.
- **`add-native-addon-delivery-models` / `add-native-addon-build-signing` / `add-hermetic-native-addon-builds`:** govern how the new add-on artifact is built, signed, and delivered (`addon.yaml`, `pushed-artifact` + `agent-sidecar`).
- **Coordinates with `add-cti-signal-coverage` (in-flight):** that change proposes managed DNS telemetry + CTI domain matching. RPZ hits emitted here are exactly those CTI signals; the OCSF DNS event schema (class_uid 4003) must be compatible with that change's domain-CTI consumer so the two do not build parallel DNS observation models.

## Impact
- **Affected specs:** `agent-feature-sets` (ADDED, depends on `add-agent-feature-sets`), `observability-signals` (ADDED), `ingestion-routing` (ADDED)
- **Affected code:**
  - `proto/agent/addon/v1/addon.proto` — new telemetry streaming RPC + batch messages
  - `rust/addon-sdk` — telemetry emitter API + capability advertisement helper
  - `go/pkg/addon`, `go/pkg/agent/addon` — manager drains telemetry only from capability-advertising add-ons
  - `go/pkg/agent` — batching, bounded queues, drop counters, forward via `StreamStatus` with `source=addon:<id>` (template: `go/pkg/agent/push_loop_flow_attribution.go`)
  - new `rust/` PowerDNS protobuf add-on package + vendored `dnsmessage.proto` (proto2) + `addons/<name>/addon.yaml`
  - `elixir/serviceradar_core` — register `pdns.ocsf` stream in `lib/serviceradar/event_writer/config.ex` + a DNS RPZ processor (template: `processors/trivy_reports.ex`); reuse `OCSF.class_dns_activity` (`ocsf.ex:53`)
  - `go/pkg/consumers/db-event-writer` — consume `pdns.ocsf` → `ocsf_events`
  - SRQL catalog (`elixir/web-ng/.../srql/catalog.ex`) — DNS event query fields
  - Bazel `BUILD` files for the new `.proto`/prost sources and add-on package (required, or `bazel test` breaks even when `cargo`/`go test` pass)
