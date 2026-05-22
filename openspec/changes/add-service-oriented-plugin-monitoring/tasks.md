## 1. Foundation
- [x] 1.1 Model monitored services, service groups, monitoring bindings, check instances, and latest check state in the `platform` schema through Elixir migrations.
- [x] 1.2 Define Ash resources/actions/policies for service targets, groups, bindings, check instances, and bulk import batches.
- [x] 1.3 Add migration/backfill paths from existing `service_checks`, `service_state`, and plugin-result service identities where mappings are unambiguous.
- [x] 1.4 Add SRQL entities/fields for monitored services, check instances, service groups, target associations, and availability rollups.
- [x] 1.5 Model SLIs, SLOs, compliance periods, error-budget state, and burn-rate evaluations in the `platform` schema through Elixir migrations.
- [x] 1.6 Define Ash resources/actions/policies/state machines/audit history for SLI definitions, SLO objectives, evaluation state, and budget lifecycle.

## 2. Plugin Contracts
- [x] 2.1 Extend plugin package manifest validation with versioned `check_descriptors`.
- [x] 2.2 Store approved descriptor metadata with package versions and expose descriptor catalogs to the UI/API.
- [x] 2.3 Update the assignment compiler to materialize monitoring bindings into descriptor-aware plugin assignments with concrete target batches.
- [x] 2.4 Add result ingestion support for target-scoped plugin results and stable `check_instance_id` identities.

## 3. Credentials and Runtime Safety
- [x] 3.1 Integrate monitoring bindings with unified credential rules and per-device/per-service overrides.
- [x] 3.2 Extend broker grants for target-bound HTTP/database/TCP/TLS checks without plaintext in assignment params.
- [x] 3.3 Add redaction tests for params, logs, result details, event payloads, and UI payloads.
- [x] 3.4 Enforce allowlist derivation from trusted service/device targets and descriptor requirements.

## 4. SDKs
- [x] 4.1 Update `~/src/serviceradar-sdk-go` with check descriptor declaration helpers, normalized target decoding, credential grant references, and target-scoped result helpers.
- [x] 4.2 Update `~/src/serviceradar-sdk-rust` with equivalent APIs and schema fixtures.
- [x] 4.3 Add cross-SDK conformance fixtures so Go and Rust serialize/deserialize the same descriptor, input, and result payloads.

## 5. UI
- [ ] 5.1 Add service inventory and service detail screens with associated-device, check, status, tag, and history views.
- [ ] 5.2 Add device-detail monitoring workflows that show eligible plugin/built-in checks for the current device.
- [ ] 5.3 Add searchable modal pickers for devices and services with filters, preview counts, pagination, and bulk selection.
- [ ] 5.4 Add URL/database/service bulk import and validation flows.
- [ ] 5.5 Add monitoring binding forms for descriptor selection, targets, schedule, credentials, thresholds, and event/alert policy.
- [ ] 5.6 Add SLI/SLO creation and detail workflows with request/window SLI type, compliance period, goal, error-budget, burn-rate, owner, and alert policy controls.

## 6. Events, Alerts, and Dashboards
- [x] 6.1 Normalize check state transitions into OCSF events according to binding policy.
- [x] 6.2 Wire event-to-alert promotion using existing stateful rule/cooldown behavior.
- [x] 6.3 Evaluate request-based and windows-based SLO compliance, error budgets, burn rates, and budget exhaustion state.
- [ ] 6.4 Normalize SLO compliance, budget, and burn-rate transitions into informational/warning/critical OCSF events.
- [ ] 6.5 Wire SLO burn-rate and budget-exhaustion event-to-alert promotion using existing stateful rule/cooldown behavior.
- [ ] 6.6 Build a service availability/SLO/NOC dashboard package with the dashboard SDK and SRQL-driven filters.
- [ ] 6.7 Add demo data and documentation showing 200 URL checks, 200 database checks, device-tag-driven service monitoring, and SLO/error-budget workflows.

## 7. Validation
- [x] 7.1 Run `openspec validate add-service-oriented-plugin-monitoring --strict`.
- [x] 7.2 Add focused unit/integration tests for compiler behavior, credential scoping, target chunking, result ingestion, and SRQL.
- [x] 7.3 Add focused unit/integration tests for request-based SLOs, windows-based SLOs, rolling/calendar compliance periods, error budgets, and burn-rate transitions.
- [ ] 7.4 Add LiveView/browser coverage for picker, bulk import, device monitoring, service inventory, and SLO workflows.
- [ ] 7.5 Run applicable Elixir, Go, Rust, and dashboard SDK tests before implementation PRs are merged.
