# Design: add-falco-ocsf-event-consumer

## Context

Falco sidekick is publishing runtime detections into JetStream (`falco_events`, subjects like `falco.notice.contact_k8s_api_server_from_container`).

ServiceRadar already runs an Elixir Broadway EventWriter pipeline, but the current routing and parser logic expects `events.*` payloads that are already OCSF-shaped. Falco payloads are currently unhandled and are acknowledged by the default processor without database writes.

## Goals / Non-Goals

- Goals:
  - Consume Falco JetStream subjects through Broadway.
  - Normalize Falco payloads into OCSF Event Log Activity rows in `platform.ocsf_events`.
  - Keep ingestion idempotent and resilient to redeliveries or malformed messages.
  - Preserve enough original Falco context for incident investigation.
- Non-Goals:
  - Changing Falco publisher format.
  - Introducing new CNPG tables or schema migrations.
  - Building Falco-specific UI pages (existing Events UI is sufficient for this change).

## Decisions

### 1. Reuse EventWriter Broadway Instead of New Pipeline

Falco ingestion will be added as another EventWriter stream/subject route instead of building a second Broadway pipeline. This keeps deployment and operations simple and reuses existing NATS, ack, telemetry, and DB write patterns.

### 2. Add Dedicated Falco Normalization Processor

Implement a Falco-specific processor module for readability and testability, then persist to `ocsf_events` using the same insert and PubSub/stateful-alert hooks used by Event Log Activity writes.

### 3. OCSF Mapping Contract

Falco payloads map to OCSF Event Log Activity (`class_uid=1008`) with deterministic fields:

- `id`: `uuid` from Falco payload when valid; deterministic fallback ID when missing.
- `time`: payload `time` (fallback to Broadway receive timestamp).
- `class_uid`: `1008`.
- `category_uid`: `1`.
- `activity_id`: `3` (`Update`).
- `type_uid`: `100803`.
- `activity_name`: `"Update"`.
- `message`: Falco `output` (fallback to rule/subject).
- `severity_id` / `severity`: mapped from Falco `priority`.
- `status_id` / `status`: mapped from Falco `priority` using explicit policy.
- `log_name`: JetStream subject (for example `falco.notice.*`).
- `log_provider`: `"falco"`.
- `metadata` / `unmapped`: include Falco fields (`rule`, `priority`, `source`, `hostname`, `tags`, `output_fields`).
- `raw_data`: original message JSON.

Priority/status mapping policy:

| Falco priority (case-insensitive) | OCSF severity_id | OCSF severity      | OCSF status_id | OCSF status |
|-----------------------------------|------------------|--------------------|----------------|-------------|
| `emergency`, `alert`              | `6`              | `Fatal`            | `2`            | `Failure`   |
| `critical`                        | `5`              | `Critical`         | `2`            | `Failure`   |
| `error`, `err`                    | `4`              | `High`             | `2`            | `Failure`   |
| `warning`, `warn`                 | `3`              | `Medium`           | `2`            | `Failure`   |
| `notice`                          | `2`              | `Low`              | `1`            | `Success`   |
| `informational`, `info`, `debug`  | `1`              | `Informational`    | `1`            | `Success`   |
| missing/unrecognized              | `0`              | `Unknown`          | `99`           | `Other`     |

### 4. Subject and Stream Defaults

Use default routing values that match issue #2985:

- stream: `falco_events`
- subject filter: `falco.>`

Allow overrides through EventWriter configuration for environments that use different naming.

### 5. Failure Handling

Malformed or unsupported Falco messages are acknowledged after being counted/logged, so poison messages do not block the pipeline. This matches current EventWriter behavior and protects ingestion continuity.

## Risks / Trade-offs

- High Falco volume can increase writes to `ocsf_events`.
  - Mitigation: keep batch settings configurable and rely on existing idempotent insert behavior.
- Priority-to-severity mapping may need tuning by operators.
  - Mitigation: document mapping and keep it centralized for future adjustments.
- Acknowledge-on-drop can hide bad payloads unless monitored.
  - Mitigation: add explicit telemetry counters and warning logs for parse failures.

## Migration Plan

1. Add Falco stream/subject config and processor wiring.
2. Deploy with EventWriter enabled.
3. Publish sample Falco events; verify `platform.ocsf_events` writes and UI visibility.
4. Monitor parse/drop counters and adjust mapping if needed.

Rollback: remove Falco stream/subject config entry to stop Falco consumption.

## Open Questions

- Should repeated identical Falco events in short windows be aggregated before insert, or left as one-row-per-event?
