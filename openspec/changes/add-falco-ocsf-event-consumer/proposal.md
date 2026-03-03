# Proposal: add-falco-ocsf-event-consumer

## Why

Issue #2985 confirms Falco sidekick is already publishing security events into NATS JetStream (`falco_events` stream, `falco.*` subjects), but ServiceRadar is not persisting those messages into `ocsf_events`.

Today, the EventWriter Broadway pipeline routes `events.>`, `otel.*`, `bmp.*`, and flow subjects. Falco subjects currently fall through the default processor and are acknowledged without persistence. This leaves runtime security detections out of the Events UI and alert workflows.

## What Changes

- Add a Falco ingestion path in the Elixir Broadway EventWriter pipeline for `falco.>` subjects (default stream `falco_events`).
- Normalize Falco payloads into OCSF Event Log Activity records and persist them to `platform.ocsf_events`.
- Apply a deterministic Falco priority policy:
  - `Emergency|Alert -> severity_id=6 (Fatal), status_id=2 (Failure)`
  - `Critical -> severity_id=5 (Critical), status_id=2 (Failure)`
  - `Error -> severity_id=4 (High), status_id=2 (Failure)`
  - `Warning -> severity_id=3 (Medium), status_id=2 (Failure)`
  - `Notice -> severity_id=2 (Low), status_id=1 (Success)`
  - `Informational|Info|Debug -> severity_id=1 (Informational), status_id=1 (Success)`
  - Unknown/missing priority -> `severity_id=0 (Unknown), status_id=99 (Other)`
- Preserve original Falco payload context (`rule`, `priority`, `hostname`, `output_fields`, `tags`, full raw JSON) for investigation and replay.
- Keep ingestion reliable under duplicates and malformed payloads (idempotent inserts, telemetry/logging for dropped messages).
- Add automated tests for subject routing, normalization, deduplication, and error handling.

## Impact

- Affected specs: `observability-signals`
- Affected systems:
  - `elixir/serviceradar_core` EventWriter Broadway producer/pipeline/processors
  - CNPG `platform.ocsf_events` write path (no schema change expected)
  - Events UI data availability in `elixir/web-ng` (reads from `ocsf_events`)
- Operational impact:
  - Higher `ocsf_events` write volume from Falco runtime detections
  - New EventWriter telemetry for Falco parse/drop counts
- Dependencies:
  - Falco publishers are already writing to JetStream (as shown in issue #2985)
  - Complements `add-falco-nats-integration` (publish side)
