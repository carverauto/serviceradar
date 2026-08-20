## 1. Spec and design
- [x] 1.1 Validate this change with `openspec validate scale-netflow-ingest-isolation --strict`.
- [x] 1.2 Confirm no conflicting active change owns the `flows` stream name or dual EventWriter pipeline (search `openspec/changes`).
- [x] 1.3 Record demo NATS PVC / `max_file_store` headroom and choose demo stream size that fits (R=3, 8 GiB flows, 30G file store / 30Gi PVC with reduced datasvc reservations).

## 2. Dedicated `flows` JetStream stream (collector)
- [x] 2.1 Add flow-collector config fields for `stream_max_age` (and document defaults); keep `stream_max_bytes` / `stream_replicas`.
- [x] 2.2 Change default / chart default `stream_name` for flow path to `flows` (overrideable).
- [x] 2.3 On stream **create**, set subjects, `max_bytes`, `max_age`, replicas, file storage, discard-old.
- [x] 2.4 On stream **update**, reconcile subjects union, replicas, `max_bytes`, and `max_age` (not only subjects/replicas).
- [x] 2.5 Add unit tests for stream ensure/reconcile config payloads.
- [x] 2.6 Update `docs/docs/netflow.md` architecture diagram and config examples for the `flows` stream.

## 3. Helm and NATS storage defaults
- [x] 3.1 Set production chart defaults for `flowCollector.config.stream_name=flows`, `stream_max_bytes` (10 GiB class within 30Gi PVC), `stream_max_age`, replicas=3.
- [x] 3.2 Replace demo shared 1 GiB flow pin with a **dedicated** flows budget (8 GiB / 2h under the 30Gi PVC) and comment why.
- [x] 3.3 Size NATS `jetstream.maxFileStore` (30G) and datasvc KV/object reservations so R=3 flows@10GiB fits the existing 30Gi PVC without Helm PVC mutation.
- [x] 3.4 Log-collector/OTEL remain on `events` only (do not ensure `flows`).

## 4. EventWriter flow demand domain
- [x] 4.1 Split flow stream definitions (`NETFLOW_RAW`, `SFLOW_RAW`) into `default_flow_streams/0` / `flow_streams` config.
- [x] 4.2 Start a second Broadway pipeline (`EventWriter.FlowPipeline`) with its own producer name/demand.
- [x] 4.3 Supervise the flow pipeline alongside the existing EventWriter pipeline under `EVENT_WRITER_ENABLED`.
- [x] 4.4 Remove raw flow subjects from the shared pipeline stream list.
- [x] 4.5 Set flow-specific defaults: pull batch 64, max_ack_pending 1024, batch_size 100.

## 5. Long-poll demand-coupled pulls (flow producer)
- [x] 5.1 Implement expires-based JetStream pull when `pull_expires_ns > 0` (flow pipeline default 2s).
- [x] 5.2 Flow path uses a slower idle tick (5s) instead of 100ms no_wait churn.
- [x] 5.3 Keep bounded in-process buffer + NAK overflow as safety.
- [x] 5.4 Unit tests for config/load_flow and existing producer flow-control tests (pass with `--no-start`).

## 6. Shared `events` path hygiene
- [x] 6.1 Flow-collector rehomes `flows.raw.*` subjects off `events` before creating `flows` (subject exclusivity).
- [x] 6.2 Single publish target `flows` after cutover (no dual CNPG writers for the same message).
- [ ] 6.3 Drain and delete obsolete netflow durables on `events` after demo roll (ops).
- [x] 6.4 Update `openspec/notes/sr-data-flow.md` and netflow docs.
- [x] 6.5 Add a guarded pre-downgrade helper/runbook that runs the current-image reverse transfer before restoring a legacy Helm revision; plain old-image rollback is explicitly unsupported.

## 7. Observability and SLO checks
- [x] 7.1 Existing EventWriter pull/queue telemetry applies per producer (flow pipeline included).
- [x] 7.2 Flow lag reporter combines consumer INFO with one stream INFO poll per unique flow stream, exposing MaxBytes/current-byte and MaxAge/oldest-message-age utilization plus backlog-gated retention risk.
- [x] 7.3 Document operator checks in netflow docs / design.
- [ ] 7.4 Optional dashboard copy clarification (deferred).

## 8. Tests and verification
- [x] 8.1 Elixir config + producer flow-control tests (`mix test ... --no-start`).
- [x] 8.2 Rust flow-collector tests (`cargo test -p serviceradar-flow-collector`).
- [x] 8.3 Helm values updated for stream name/size (template embeds config JSON).
- [ ] 8.4 Full `elixir_quality.sh` (needs local CNPG/test DB).
- [ ] 8.5 Demo verification after image roll.
- [x] 8.6 Shared pipeline no longer registers NETFLOW_RAW/SFLOW_RAW (config tests).
- [x] 8.7 Compose `network-ingest` reservations fit the generated platform-account and NATS server budgets with regression coverage.
- [x] 8.8 Pre-downgrade helper contract test proves target validation and reverse-transfer preparation happen before `helm rollback`.

## 9. Delivery
- [ ] 9.1 Roll demo with sized NATS storage + `flows` stream; confirm nats cluster healthy (R=3).
- [ ] 9.2 Summarize before/after lag metrics in the PR.
- [ ] 9.3 Open Forgejo PR against a feature branch (never push to `staging` directly).
