# Tasks: add-falco-ocsf-event-consumer

## 1. EventWriter Ingestion Wiring

- [x] 1.1 Add a Falco stream definition to EventWriter config (default stream `falco_events`, subject `falco.>`).
- [x] 1.2 Route `falco.*` subjects to an OCSF event persistence processor instead of the default drop/ack processor.
- [x] 1.3 Ensure durable JetStream consumer names and delivery subjects are deterministic for Falco stream subscriptions.

## 2. Falco-to-OCSF Normalization

- [x] 2.1 Implement a Falco event processor in `elixir/serviceradar_core` that converts Falco payload JSON into OCSF Event Log Activity rows for `ocsf_events`.
- [x] 2.2 Map Falco `priority` to OCSF `severity_id`/`severity` and `status_id`/`status` using the approved deterministic policy, and set class/category/type/activity values for Event Log Activity.
- [x] 2.3 Persist forensic context (`rule`, `output`, `output_fields`, `tags`, `hostname`, source subject) into OCSF metadata/unmapped fields and `raw_data`.
- [x] 2.4 Handle idempotency: reuse Falco `uuid` when present; otherwise derive a deterministic event ID so redeliveries do not create duplicates.
- [x] 2.5 Emit PubSub refresh and stateful rule evaluation for newly inserted Falco-backed OCSF events.

## 3. Test Coverage

- [x] 3.1 Add unit tests for Falco payload parsing and OCSF field mapping (including sample payload shape from issue #2985).
- [x] 3.2 Add mapping tests for `Warning`, `Notice`, and unknown priority values to verify exact severity/status outputs.
- [x] 3.3 Add tests for routing (`falco.*` goes to Falco/Events processor, not default processor).
- [ ] 3.4 Add duplicate/retry tests to verify idempotent writes into `ocsf_events`.
- [x] 3.5 Add malformed payload tests to verify messages are acknowledged, counted, and logged without blocking Broadway.

## 4. Validation & Documentation

- [ ] 4.1 Manual validation: publish sample Falco messages to JetStream and verify rows appear in `platform.ocsf_events`.
- [ ] 4.2 Manual validation: confirm Events UI in `web-ng` surfaces persisted Falco events.
- [x] 4.3 Update Falco integration docs with the consumer path and verification commands.
- [x] 4.4 Run targeted tests and compile checks (`mix test` for touched modules, `mix compile`).
