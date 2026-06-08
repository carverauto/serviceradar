## Context
The native add-on contract is intentionally minimal: `AddonService` exposes exactly `Info`, `Configure`, and `Health` over the HashiCorp go-plugin transport (subprocess + gRPC on a restricted Unix-domain socket with AutoMTLS) — see `proto/agent/addon/v1/addon.proto:29-43`. That proves Go↔Rust interop (`add-native-addon-rust-sdk`, complete) but provides no way for an add-on to *produce* telemetry. The only extension point today is the opaque `InfoResponse.capabilities` string list (`addon.proto:50`).

PowerDNS protobuf logging is a producer-specific wire format. PowerDNS Recursor streams query/response messages, and RPZ policy decisions carry policy name, match dimension, trigger, hit, and action. ServiceRadar should not expose the cluster OTEL collector (`rust/otel`) to every DNS server to decode that local stream; the DNS VMs already run `serviceradar-agent` and should use the normal outbound, partition-attested agent path.

Existing ServiceRadar patterns this change builds on (verified):
- **Netprobe flow attribution is the forwarding template — but note the distinction.** Netprobe is *not* a go-plugin add-on; it is a capability-granted sidecar (`addons/netprobe/addon.yaml`: `supervision: systemd-service`) speaking a bespoke `NetprobeFrame` Unix-socket IPC, because it needs `CAP_BPF`/`CAP_NET_RAW`. What this change reuses from it is the **agent→gateway leg**: the agent drains a bounded queue, batches, and forwards via `AgentGatewayService.StreamStatus(stream GatewayStatusChunk)` using `GatewayServiceStatus.source="flow-attribution"`, with the batch serialized as opaque `bytes message` and a `dropped_since_last` counter (`go/pkg/agent/push_loop_flow_attribution.go`; limits 4096 events/chunk, 6 MiB/message, 32768/push tick). The PowerDNS add-on differs only in that it is an unprivileged go-plugin add-on emitting to the agent over the add-on gRPC contract rather than bespoke IPC.
- **`db-event-writer` is the OCSF sink.** The Go consumer `go/pkg/consumers/db-event-writer` reads JSON OCSF events from NATS and inserts into `ocsf_events` via `InsertOCSFEvents` with `ON CONFLICT (id, time) DO NOTHING` (`go/pkg/db/ocsf_events.go:50`). Subjects are registered in core-elx `EventWriter` config, not in db-event-writer. (Note: Broadway in core-elx *consumes from* NATS — it is not the publish hop. The accurate path is: agent → gateway → core-elx publishes to a NATS subject → `db-event-writer` consumes → CNPG.)
- **Trivy is the closest precedent** for a security finding → NATS (`trivy.report.>`) → core-elx processor → `ocsf_events` flow.
- **OCSF taxonomy already exists.** `OCSF.class_dns_activity → 4003` is already defined (`elixir/.../event_writer/ocsf.ex:53`), just unused. `ocsf_events` (generic, JSONB-blob, 14-day) and `ocsf_network_activity` (dedicated wide-column hypertable for flows, 90-day, with rollup CAGGs) are both live — ServiceRadar already has both the "generic event store" and "dedicated wide-column table" precedents.

## Goals
- Provide a reusable native add-on telemetry contract for local log sources, with backward compatibility for existing add-ons.
- Keep PowerDNS-specific decoding in a Rust add-on, not in agent core.
- Preserve trusted agent/gateway/partition/hostname/source-IP metadata via the existing authenticated agent path.
- Avoid opening OTEL collector ports to DNS hosts.
- Keep default volume bounded by ingesting only RPZ/policy hits unless full DNS logging is explicitly enabled.
- Emit OCSF DNS Activity (4003) events that are directly correlatable for CTI against DNS names, client IPs, policy names, and response decisions.

## Non-Goals
- Do not replace the existing syslog (`flowgger`/`log-collector`), OTEL (`rust/otel`), SNMP-trap (`trapd`), or flow (`flow-collector`) collectors.
- Do not require direct database or NATS writes from DNS hosts.
- Do not make Wasm plugins run arbitrary long-lived TCP listeners in this change.
- Do not ingest the full DNS query firehose by default.
- Do not make PowerDNS authoritative zone replication depend on this telemetry add-on.

## Decisions

### D1: Native add-on first, Wasm deferred
Use a Rust native add-on for the first implementation. It needs a long-lived localhost TCP listener for PowerDNS protobuf, decode state, backpressure, and batch emission — none of which the request/response Wasm plugin model supports without being extended for long-lived listeners and streaming output. Reuse the go-plugin/AutoMTLS supervision and packaging already proven by `add-native-addon-rust-sdk` and `addons/rust-sample-addon`.

### D2: Add a generic telemetry stream to the add-on contract, capability-gated
Extend `AddonService` with a new server-streaming RPC (add-on→agent), e.g. `rpc StreamTelemetry(StreamTelemetryRequest) returns (stream TelemetryBatch)` (or an agent-initiated `Drain`; either way it stays inside `serviceradar.agent.addon.v1`, no new package — v1 + additive RPC, not v2). The payload is source-agnostic — a `TelemetryBatch` carrying:
- source type and source instance
- observed time and event time
- stable event identity / idempotency key
- payload kind enum (`ocsf_event`, `otel_log`, … extensible; PowerDNS uses `ocsf_event`)
- payload bytes
- local source metadata and producer counters (received / filtered / emitted / dropped, plus queue depth)

Backward compatibility: an add-on advertises `native-telemetry:v1` in `InfoResponse.capabilities`; the agent only opens the telemetry RPC for add-ons that advertise it. Add-ons that implement only Info/Configure/Health continue to run unchanged and report no telemetry capability. This is the concrete mechanism behind the "Legacy native add-on remains compatible" scenario.

### D3: Use the agent path for trust and tenancy
The add-on emits only to the local agent over the go-plugin transport. The agent forwards accepted batches via `StreamStatus`; the gateway attaches partition/agent/gateway identity from the authenticated mTLS envelope. Identity is derived from the certificate CN format `<component_id>.<partition_id>.serviceradar` and the gateway **ignores client-supplied `partition`/`gateway_id`** (`serviceradar_agent_gateway` `resolve_partition/2` uses `identity.partition_id`, not the request field). Add-on-supplied identity is source metadata only.

### D4: Reuse existing OCSF event ingestion; no direct DB writes
Target path: add-on → agent → gateway → core-elx → NATS (`pdns.ocsf`) → `db-event-writer` → `ocsf_events` (CNPG). Register `pdns.ocsf` (convention: `{domain}.{type}`, mirroring `trivy.report.>`) in `event_writer/config.ex` with a DNS RPZ processor modeled on `processors/trivy_reports.ex`, and add the subject→table mapping in db-event-writer. Direct DB writes from the add-on or DNS host are rejected. Direct DB writes *from core* are considered only if profiling shows the event-writer path cannot sustain policy-hit volume.

### D5: PowerDNS maps to OCSF DNS Activity (class_uid 4003), Security Control profile — RPZ is first-class, not `unmapped`
Target **OCSF v1.8.0**, class **DNS Activity (`class_uid=4003`, `category_uid=4` Network Activity)**. `type_uid = 4003*100 + activity_id` → `400301` Query, `400302` Response. Class 4003 already embeds the **Security Control** profile, so `disposition_id`, `action_id`, and the `firewall_rule` object are native attributes — RPZ data does **not** go in `unmapped`. `severity_id` is the only *required* classification field.

PBDNSMessage → OCSF 4003 mapping:

| PBDNSMessage (proto2) field | OCSF DNS Activity (4003) target |
|---|---|
| `question.qName` | `query.hostname` (strip trailing dot) |
| `question.qType` | `query.type` |
| `question.qClass` | `query.class` |
| `id` (DNS header id) | `query.packet_uid` |
| `response.rrs[].{type,class,ttl,rdata}` | `answers[].{type,class,ttl,rdata}` |
| `response.rcode` | `rcode_id` (+ `rcode` string); special-case `65536` network-error → `rcode_id=99`, `status_id`=Failure |
| `timeSec`/`timeUsec` | `response_time` |
| `response.queryTimeSec`/`queryTimeUsec` | `query_time` |
| `from` + `fromPort` (raw 4/16 NBO bytes → IpAddr) | `src_endpoint` (ip/port) |
| `to` + `toPort` | `dst_endpoint` (ip/port) |
| `socketFamily` / `socketProtocol` | `connection_info` |
| `response.appliedPolicy` | `firewall_rule.name` |
| `response.appliedPolicyType` (PolicyType enum) | `firewall_rule.category` |
| `response.appliedPolicyKind` (PolicyKind enum, the action) | `firewall_rule.type` + drives `action_id`/`disposition_id` |
| `response.appliedPolicyTrigger` | `firewall_rule.condition` |
| `response.appliedPolicyHit` | `firewall_rule.match_details[]` |
| `newlyObservedDomain`, `deviceId`, `deviceName`, `tags` | `unmapped` / `enrichments` (truly non-OCSF extras only) |

RPZ action (`appliedPolicyKind`) → OCSF Security Control:

| PolicyKind | `action_id` | `disposition_id` | default `severity_id` |
|---|---|---|---|
| `NoAction` (1) | 1 Allowed | 1 Allowed | 1 Informational |
| `NXDOMAIN` (3) / `NODATA` (4) / `Truncate` (5) | 2 Denied | 2 Blocked | 3 Medium |
| `Drop` (2) | 2 Denied | 6 Dropped | 3 Medium |
| `Custom` (6) | 2 Denied (or 99) | 7 Custom Action | 3 Medium |

PolicyType (match dimension) enum: `UNKNOWN=1, QNAME=2, CLIENTIP=3, RESPONSEIP=4, NSDNAME=5, NSIP=6`. Store the OCSF schema version on each row for forward-compat.

### D6: Forward via existing `StreamStatus` with a `source` discriminator — no new gateway RPC
Open question resolved: the agent forwards add-on telemetry on the existing `AgentGatewayService.StreamStatus` using `GatewayServiceStatus.source="addon:<addon_id>"` (e.g. `addon:powerdns`), with the `TelemetryBatch` serialized into `bytes message`. Rationale: the source-discriminator pattern is already proven (`status`, `results`, `sysmon-metrics`, `plugin-telemetry`, `flow-attribution`); `StreamStatus` already handles 16 MiB chunks / 64 MiB windows (flow-attribution pushes up to 15 MiB messages), far above RPZ-only batch sizes; core already routes on `source` and the gateway already attests identity (D3). A dedicated RPC would duplicate framing, windowing, retry, and backpressure for no benefit. Reserve an `addon:` source prefix to avoid collisions with native sources.

### D7: Persist in `ocsf_events` keyed on `class_uid=4003` for v1; graduate to a dedicated table only if profiling demands it
v1 writes DNS events to the generic `ocsf_events` store via db-event-writer's existing OCSF insert (`ON CONFLICT (id, time)`), the minimal-code path consistent with D4 and the project's "simplicity first" rule. Default RPZ-hit-only volume is low by design, so the generic store is appropriate. The known trade-off: `ocsf_events` indexes only `time`/`severity_id` and stores endpoints as JSONB, so CTI predicates on `query.hostname`/`firewall_rule.name`/`client_ip` rely on JSONB extraction.

Escalation path (mirrors D4's philosophy, and ServiceRadar already has the precedent in `ocsf_network_activity`): if profiling shows CTI dashboards/rollups on (domain, client_ip, policy, action) cannot be served from the JSONB store at observed volume, graduate to either (a) generated/indexed columns + a DNS-specific TimescaleDB continuous aggregate (blocked-by-policy, top-blocked-domains) on `ocsf_events`, or (b) a dedicated `ocsf_dns_activity` wide-column hypertable following the `ocsf_network_activity` migration/CAGG pattern, with an SRQL catalog entry exposing `queried_domain`/`client_ip`/`dns_server`/`policy_name`/`policy_action` as indexed scalar filter fields. This decision is reversible because the write contract (OCSF 4003 JSON) and idempotency key (`id`,`time`) are stable regardless of physical table.

### D8: Vendor PowerDNS `dnsmessage.proto` (proto2) from canonical source; 2-byte framing; RPZ-only Recursor config
- **Schema source:** vendor `dnsmessage.proto` from the standalone canonical **`PowerDNS/dnsmessage`** repo (MIT), *not* `pdns/pdns/.../dnsmessage.proto` (a downstream vendored copy that "must not be directly updated"). Pin an explicit git tag/commit recorded in the proposal; current master is acceptable (proto2, additive fields only). The RPZ fields (`appliedPolicyType=7`, `appliedPolicyTrigger=8`, `appliedPolicyHit=9`, `appliedPolicyKind=10`) are stable since Recursor ~4.3.
- **proto2, not proto3:** `PBDNSMessage` is proto2. Generate Rust with `prost-build` (proto2-capable); scalar fields become `Option<T>`. Update Bazel `BUILD` deps for the `.proto` + generated sources (project lesson: `bazel test` breaks even when `cargo`/`go test` pass otherwise).
- **TCP wire framing:** PowerDNS `protobufServer` streams over TCP as repeated `[uint16 big-endian length][PBDNSMessage bytes]`. Read 2 bytes BE, then exactly N bytes, then decode; cap/validate N at 65535. The 4-byte length form is framestream/dnstap only — do not implement it.
- **Recursor emitter config to document:** `protobufServer()` (Lua) / `logging.protobuf_servers` (YAML, Recursor 5.1.0+) with `logResponses=true` and `taggedOnly=true` to forward only RPZ-policy/tagged messages (the volume control behind the RPZ-only default), and `setProtobufMasks()` for client-IP anonymization. `outgoingProtobufServer` is **not** needed (RPZ verdicts are on the client-facing response).

## Risks
- **Volume blow-up:** full DNS query logging can exceed storage budgets. Mitigate with default RPZ-only (`taggedOnly=true` at the source *and* policy-hit filtering in the add-on), bounded queues, batch limits, and drop counters.
- **Contract churn:** adding telemetry emission changes a young SDK. Keep messages generic, versioned, and capability-gated so older add-ons are unaffected.
- **proto2/prost + Bazel:** the vendored proto is proto2 and adds generated sources; missing Bazel `BUILD` updates break hermetic builds even when local test commands pass.
- **OCSF schema drift:** stamp the OCSF schema version (1.8.0) per row and keep PowerDNS source extras in `unmapped`/`enrichments` so events stay re-projectable.
- **Backpressure:** PowerDNS may reconnect/block when the add-on cannot drain. Expose queue depth, dropped records, and decode errors via Health and the batch counters.
- **CTI duplication:** without coordination, this change and `add-cti-signal-coverage` could build parallel DNS models. Mitigate by sharing the OCSF 4003 event shape.

## Open Questions
- Do we need local disk spooling for WAN outages in v1, or are bounded in-memory queues plus drop counters sufficient for RPZ-only volume? (Lean: in-memory for v1, matching netprobe.)
- Should PowerDNS-native DNS events share one DNS observation model with `add-cti-signal-coverage`'s managed-resolver/log-ingestion sources, or stay separate OCSF 4003 events projected for CTI matching? (Needs cross-change agreement.)
- Exact SRQL surface for DNS events at v1: query the generic `events` entity filtered by `class_uid=4003`, or add a dedicated `dns_events` catalog entity now vs. at the D7 escalation?
