# Design: add-falco-ocsf-event-consumer

## Context

Falco sidekick is publishing runtime detections into JetStream (`falco_events`, subjects like `falco.notice.contact_k8s_api_server_from_container`).

ServiceRadar needs a dual-path posture for Falco:

- Keep raw payloads in `platform.logs` for investigation and replay.
- Promote only higher-signal priorities to `platform.ocsf_events`.
- Trigger immediate alerts for the highest severities.

## Goals / Non-Goals

- Goals:
  - Consume Falco JetStream subjects through EventWriter Broadway.
  - Persist all Falco payloads as raw log records.
  - Auto-promote warning+ Falco priorities into OCSF events.
  - Auto-create alerts for critical/fatal promoted events.
  - Keep ingestion idempotent and resilient to malformed payloads.
- Non-Goals:
  - Changing Falco publisher format.
  - Introducing new CNPG tables or schema migrations.
  - Building Falco-specific UI pages.

## Decisions

### 1. Reuse EventWriter Broadway Instead of New Pipeline

Falco ingestion is implemented as an EventWriter stream/subject route, reusing existing NATS, ack, telemetry, and DB write patterns.

### 2. Dedicated Falco Processor Implements Dual Path

`ServiceRadar.EventWriter.Processors.FalcoEvents` handles both storage paths in one batch:

1. Parse Falco payload.
2. Write raw log row into `logs`.
3. Build OCSF event candidate.
4. Promote to `ocsf_events` only when severity threshold matches.
5. Generate priority alerts for critical/fatal promoted events.

### 3. Priority Mapping Contract

Falco `priority` values map deterministically to OCSF severity/status:

| Falco priority (case-insensitive) | OCSF severity_id | OCSF severity      | OCSF status_id | OCSF status |
|-----------------------------------|------------------|--------------------|----------------|-------------|
| `emergency`, `alert`              | `6`              | `Fatal`            | `2`            | `Failure`   |
| `critical`                        | `5`              | `Critical`         | `2`            | `Failure`   |
| `error`, `err`                    | `4`              | `High`             | `2`            | `Failure`   |
| `warning`, `warn`                 | `3`              | `Medium`           | `2`            | `Failure`   |
| `notice`                          | `2`              | `Low`              | `1`            | `Success`   |
| `informational`, `info`, `debug`  | `1`              | `Informational`    | `1`            | `Success`   |
| missing/unrecognized              | `0`              | `Unknown`          | `99`           | `Other`     |

### 4. Promotion Threshold Policy

- **Logs path**: all valid Falco payloads are persisted.
- **Events path**: only severity `>= 3` (`Warning` and above) is promoted to `ocsf_events`.
- **Alert path**: only severity `>= 5` (`Critical`, `Alert`, `Emergency`) auto-creates alerts.

### 5. Event and Log Correlation

Promoted OCSF events carry provenance metadata linking back to the raw Falco log row (`source_log_id`) so operators can pivot from event/alert to full payload context.

### 6. Subject and Stream Defaults

Use defaults that match issue #2985:

- stream: `falco_events`
- subject filter: `falco.>`

Allow overrides via EventWriter configuration.

### 7. Failure Handling

Malformed or unsupported Falco messages are acknowledged after telemetry/logging. Poison messages do not block the pipeline.

## Risks / Trade-offs

- Full raw-log persistence increases `platform.logs` write volume.
  - Mitigation: retain promoted-event thresholding and existing log retention controls.
- Immediate high-severity alerting can create noise during bursts.
  - Mitigation: tie alert creation to critical/fatal only, and rely on alert lifecycle controls.
- Idempotency depends on stable identity/timestamp extraction.
  - Mitigation: deterministic IDs and stable timestamp fallbacks.

## Migration Plan

1. Add Falco stream/subject config and processor wiring.
2. Deploy with EventWriter enabled.
3. Publish sample Falco events; verify:
   - `logs` receives all payloads
   - `ocsf_events` receives warning+
   - alerts are created for critical/fatal
4. Monitor drop/promote/alert telemetry and tune thresholds if needed.

Rollback: remove the Falco stream entry from EventWriter config.

## Open Questions

- Should `Error` remain auto-promoted by default in all environments, or be deployment-configurable?
