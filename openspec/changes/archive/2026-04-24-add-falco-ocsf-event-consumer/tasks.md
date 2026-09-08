# Tasks: add-falco-ocsf-event-consumer

## 1. EventWriter Ingestion Wiring

- [x] 1.1 Add a Falco stream definition to EventWriter config (default stream `falco_events`, subject `falco.>`).
- [x] 1.2 Route `falco.*` subjects to a dedicated Falco processor instead of the default drop/ack processor.
- [x] 1.3 Ensure durable JetStream consumer names and delivery subjects are deterministic for Falco stream subscriptions.

## 2. Falco Dual-Path Processing

- [x] 2.1 Persist every valid Falco payload into `platform.logs` as OTEL-compatible raw log rows.
- [x] 2.2 Map Falco `priority` to deterministic OCSF `severity_id`/`severity` and `status_id`/`status`.
- [x] 2.3 Promote Falco payloads with severity `>= 3` (Warning+) into OCSF Event Log Activity rows in `platform.ocsf_events`.
- [x] 2.4 Auto-create alerts for promoted Falco events with severity `>= 5` (Critical/Fatal).
- [x] 2.5 Preserve forensic context (`rule`, `output`, `output_fields`, `tags`, `hostname`, source subject) and event-to-log provenance (`source_log_id`).
- [x] 2.6 Handle idempotency via deterministic identifiers and conflict-safe inserts for both logs and promoted events.
- [x] 2.7 Emit ingestion/drop/alert telemetry and run existing event workflow hooks (PubSub + stateful rule evaluation) for promoted events.

## 3. Test Coverage

- [x] 3.1 Add unit tests for Falco payload parsing and OCSF field mapping (including sample payload shape from issue #2985).
- [x] 3.2 Add mapping tests for `Warning`, `Notice`, and unknown priority values to verify exact severity/status outputs.
- [x] 3.3 Add threshold tests for event promotion (`Warning+`) and alert promotion (`Critical+`).
- [x] 3.4 Add tests for routing (`falco.*` goes to the Falco processor, not default processor).
- [x] 3.5 Add deterministic ID/retry behavior tests to verify duplicate payloads map to stable IDs.
- [x] 3.6 Add malformed payload tests to verify messages are acknowledged, counted, and logged without blocking Broadway.

## 4. Validation & Documentation

- [ ] 4.1 Manual validation: publish sample Falco messages to JetStream and verify all rows appear in `platform.logs`, Warning+ rows appear in `platform.ocsf_events`, and Critical/Fatal rows create alerts.
- [ ] 4.2 Manual validation: confirm `web-ng` Events/Alerts views surface promoted Falco records with linked context.
- [x] 4.3 Update Falco integration docs with the dual-path behavior and verification commands.
- [x] 4.4 Run targeted tests and compile checks for touched modules (`mix test`, `mix compile`).
- [x] 4.5 Validate OpenSpec change set with `openspec validate add-falco-ocsf-event-consumer --strict`.
