# OTEL Collector Add-on

Edge OpenTelemetry collector for ServiceRadar, packaged as a native
agent-sidecar add-on. It serves local OTLP/gRPC (4317) and OTLP/HTTP (4318)
listeners. The required/default install spools accepted telemetry durably on
disk and relays it to the supervising serviceradar-agent over the acked
`otlp-relay:v1` stream: no new inbound ports, no egress beyond the agent's
existing gateway connection. Sites with a local NATS leaf can explicitly use
direct JetStream publishing instead.

- Runtime implementation: `rust/otel-addon` (binary `serviceradar-otel-addon`)
  on top of the collector library in `rust/otel`.
- Operator configuration schema: [`config.schema.json`](config.schema.json),
  delivered via streamed agent config and surfaced in the add-on settings UI.

## Output transports

The add-on supports both Phase 0.12 transport shapes:

- **Gateway relay (default/required):** omit `output`, or set
  `{"output":{"backend":"agent"}}`. The add-on writes a bounded local spool
  and the supervising agent relays frames to the gateway with cumulative
  acknowledgements.
- **Direct-to-leaf:** set `{"output":{"backend":"jetstream"}}` and configure
  `nats.url` to the local NATS leaf. In this mode the collector publishes to
  JetStream directly and `RelayOtlp` is intentionally unavailable. The direct
  configuration is an explicit add-on assignment; the base agent onboarding
  bundle never contains NATS credentials or a platform NATS URL. The
  assignment must select the registered edge site whose leaf owns that URL;
  the site must be active with a connected leaf server. The direct path is
  mTLS-only: the control plane issues a short-lived add-on certificate through
  the authenticated agent-gateway CA and injects the certificate, private key,
  and CA chain only into the ready add-on configuration. The Rust runtime
  materializes those PEM values in a mode-0600 temporary directory and removes
  them when the direct runtime is replaced. `nats.creds_file` is rejected.
  The selected leaf must render the assignment's exact subject scope in its
  local `verify_and_map` authorization block; a certificate by itself is not a
  substitute for the leaf ACL.

## Spool sizing and retention

The relay spool is the durability owner between "OTLP client got OK" and "the
agent-gateway acked the frame". It is **bounded** and **self-protecting**:

- **`agent_forward.max_bytes`** (default 256 MiB) caps the on-disk spool.
  When the cap is reached, whole oldest sealed segments are evicted first and
  every evicted record is counted per signal in delivery accounting
  (`TelemetryCounters.dropped`, `otel_spool_evicted_total`). Sizing hint:
  **256 MiB buffers roughly tens of minutes at moderate edge volume.** If a
  site needs to survive multi-hour or multi-day outages, deploy a NATS leaf
  server and use the JetStream leaf transport for durability instead of
  growing the spool — the spool is a bridge buffer, not an archive.
- **`agent_forward.max_age_secs`** (optional) additionally evicts sealed
  segments older than the bound, oldest first, with the same accounting.
- **`agent_forward.min_free_disk_bytes`** (default 512 MiB) is the free-disk
  floor: when the host volume's available space drops below it (or a write
  hits ENOSPC), the spool behaves exactly as if its own bound were reached —
  evict oldest, retry once, and on persistent failure reject the incoming
  batch with per-signal rejection counts (`partial_success` to the OTLP
  client). The spool never fills the volume and never crashes on a full disk.

All three settings apply to the **running** add-on immediately: shrinking
`max_bytes` (or tightening `max_age_secs`) evicts oldest segments down to the
new bound at reconfigure time, without restarting the collector or losing the
ack watermark / relay-id sequence.

## Spool usage events (alerting)

The add-on advertises `native-telemetry:v1` and reports spool pressure as
OCSF events over the SDK telemetry stream (`AddonService.StreamTelemetry`),
which the agent forwards into the platform's `events.ocsf` pipeline.

Events are emitted on **state transitions only** plus a 5-minute heartbeat
while elevated (sampled every 30 s, with hysteresis — no per-sample spam):

| State      | Enters when                                   | Clears when            |
| ---------- | --------------------------------------------- | ---------------------- |
| `warn`     | utilization rises past 80%                    | drops below 75%        |
| `critical` | utilization rises past 95% OR eviction active | drops below 90% (and no eviction) |

Event shape: OCSF **Event Log Activity** (`class_uid` 1008, `category_uid` 1
System Activity, `activity_id` 1 Create) — the same envelope
serviceradar-core uses for its own operational state events
(`go/pkg/natsutil/events.go`), chosen because OCSF has no canonical
"resource pressure" class and this keeps spool events compatible with the
existing event-to-alert rules. Severity maps ok→Informational(1),
warn→Medium(3), critical→Critical(5); `status_code` is
`otel_spool_<state>`. The usage attributes ride in `unmapped`:
`addon_id`, `event_kind` (`rise`/`clear`/`heartbeat`), `state`,
`previous_state`, `spool_bytes_used`, `spool_max_bytes`, `utilization_pct`,
`free_disk_bytes`, `min_free_disk_bytes`, per-signal `evicted_records`
(traces/logs/metrics/derived_metrics/other/total), and `spool_dir`.
Site/agent attribution is stamped upstream by the agent from its mTLS
identity, like all native add-on telemetry.
