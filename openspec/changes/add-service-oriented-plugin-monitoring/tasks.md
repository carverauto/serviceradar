## 1. Foundation
- [ ] 1.1 Model monitored services, service groups, monitoring bindings, check instances, and latest check state in the `platform` schema through Elixir migrations.
- [ ] 1.2 Define Ash resources/actions/policies for service targets, groups, bindings, check instances, and bulk import batches.
- [ ] 1.3 Add migration/backfill paths from existing `service_checks`, `service_state`, and plugin-result service identities where mappings are unambiguous.
- [ ] 1.4 Add SRQL entities/fields for monitored services, check instances, service groups, target associations, and availability rollups.

## 2. Plugin Contracts
- [ ] 2.1 Extend plugin package manifest validation with versioned `check_descriptors`.
- [ ] 2.2 Store approved descriptor metadata with package versions and expose descriptor catalogs to the UI/API.
- [ ] 2.3 Update the assignment compiler to materialize monitoring bindings into descriptor-aware plugin assignments with concrete target batches.
- [ ] 2.4 Add result ingestion support for target-scoped plugin results and stable `check_instance_id` identities.

## 3. Credentials and Runtime Safety
- [ ] 3.1 Integrate monitoring bindings with unified credential rules and per-device/per-service overrides.
- [ ] 3.2 Extend broker grants for target-bound HTTP/database/TCP/TLS checks without plaintext in assignment params.
- [ ] 3.3 Add redaction tests for params, logs, result details, event payloads, and UI payloads.
- [ ] 3.4 Enforce allowlist derivation from trusted service/device targets and descriptor requirements.

## 4. SDKs
- [ ] 4.1 Update `~/src/serviceradar-sdk-go` with check descriptor declaration helpers, normalized target decoding, credential grant references, and target-scoped result helpers.
- [ ] 4.2 Update `~/src/serviceradar-sdk-rust` with equivalent APIs and schema fixtures.
- [ ] 4.3 Add cross-SDK conformance fixtures so Go and Rust serialize/deserialize the same descriptor, input, and result payloads.

## 5. UI
- [ ] 5.1 Add service inventory and service detail screens with associated-device, check, status, tag, and history views.
- [ ] 5.2 Add device-detail monitoring workflows that show eligible plugin/built-in checks for the current device.
- [ ] 5.3 Add searchable modal pickers for devices and services with filters, preview counts, pagination, and bulk selection.
- [ ] 5.4 Add URL/database/service bulk import and validation flows.
- [ ] 5.5 Add monitoring binding forms for descriptor selection, targets, schedule, credentials, thresholds, and event/alert policy.

## 6. Events, Alerts, and Dashboards
- [ ] 6.1 Normalize check state transitions into OCSF events according to binding policy.
- [ ] 6.2 Wire event-to-alert promotion using existing stateful rule/cooldown behavior.
- [ ] 6.3 Build a service availability/NOC dashboard package with the dashboard SDK and SRQL-driven filters.
- [ ] 6.4 Add demo data and documentation showing 200 URL checks, 200 database checks, and device-tag-driven service monitoring.

## 7. Validation
- [x] 7.1 Run `openspec validate add-service-oriented-plugin-monitoring --strict`.
- [ ] 7.2 Add focused unit/integration tests for compiler behavior, credential scoping, target chunking, result ingestion, and SRQL.
- [ ] 7.3 Add LiveView/browser coverage for picker, bulk import, device monitoring, and service inventory flows.
- [ ] 7.4 Run applicable Elixir, Go, Rust, and dashboard SDK tests before implementation PRs are merged.
