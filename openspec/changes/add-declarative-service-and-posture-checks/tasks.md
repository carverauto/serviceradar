## 1. Canonical Data Model, JSON Schema, and Credential Bindings (`serviceradar_core`)

- [ ] 1.1 Create `ServiceRadar.DeclarativeChecks` Ash domain and `DeclarativeCheck` Ash resource (`platform.declarative_checks`) with `schema_version: 1`, `slug`, `name`, `description`, `state`, `schedule`, `target_binding`, `inputs`, `credential_slots`, `nodes`, `edges`, `alert_policy`, `ui_layout`, `pack_id`, `pack_version`, `managed`, `template_fingerprint`, and `parameter_overrides` via `mix ash.codegen`
- [ ] 1.2 Create `DeclarativeCheckCredentialBinding` Ash resource (`platform.declarative_check_credential_bindings`) with restrictive foreign keys to `platform.network_credential_secrets` and `platform.network_credential_rules`, registering usage in `ServiceRadar.Credentials.CredentialUsage`, `GuardCredentialDestroy`, and `GuardCredentialRuleLifecycle`
- [ ] 1.3 Create `DeclarativeCheckInstance` (`platform.declarative_check_instances`) and `DeclarativeCheckEdgeObservation` (`platform.declarative_check_edge_observations`) Ash resources with `ServiceState` projection, `ServiceStatePubSub` broadcast, scope departure pruning, and DIRE `reassign_device` hook
- [ ] 1.4 Implement `DeclarativeChecks.CanonicalJSON` and `DeclarativeChecks.SchemaValidator` enforcing strict v1 JSON Schema validation, acyclic DAG verification, handle/port type checking, `template_fingerprint` SHA-256 calculation, and secret-free preflight guards
- [ ] 1.5 Add RBAC permission catalog entries (`declarative_checks.view`, `declarative_checks.manage`, `declarative_checks.evaluate`) and Ash policy checks across all `DeclarativeChecks` resources

## 2. Core Runner, Posture Evaluators (Pack #1 for PR #6760), and Pure DAG Engine

- [ ] 2.1 Implement pure deterministic node evaluators for `extract_field` (bounded JSONPath, HTTP header, linear-time regex, SRQL field), `threshold_assert` (`warn` / `crit` numeric/string/boolean comparators), `decision_table` (`max_age_seconds` staleness -> `unknown` and mandatory all-`*` catch-all row), and `alert_output`
- [ ] 2.2 Implement `srql_query` Core signal node routed exclusively through the SRQL AshAdapter with strict read-only, row (`<= 1_000`), and timeout (`<= 10_000ms`) enforcement
- [ ] 2.3 Implement closed `platform_posture` evaluator registry and Built-in Pack #1 (`io.serviceradar.storage-and-nvr-health`) for PR `#6760`: `storage.entitlement_utilization`, `storage.hold_pin_pressure`, `storage.archive_credential_and_usage_health`, and `camera.continuous_recording_silence`
- [ ] 2.4 Implement `CoreEvaluationWorker` (Oban `:declarative_checks` queue), 1,000-device paged `srql_devices` and `service_targets` fan-out, debounced hybrid Edge-observation refresh, `VerdictEventWriter` (OCSF `health.state_change` via `OcsfEventPublisher` -> NATS JetStream), and `StatefulAlertRule` reconciliation
- [ ] 2.5 Implement `DeclarativeChecks.LegacyImporter` pure conversion adapters (`from_service_check/1` and `from_composite_check/1`) producing draft `schema_version: 1` `DeclarativeCheck` documents with parity unit tests

## 3. Edge `declarative-check-runner` WASM Plugin and Assignment Compiler

- [ ] 3.1 Build and package the first-party `declarative-check-runner` WASI plugin (`io.serviceradar.declarative-check-runner`) with Bazel build targets and `UploadSignature` verification metadata
- [ ] 3.2 Implement `http_request`, `http_journey` (composing `httptrace` DNS/TCP/TLS/TTFB/transfer waterfalls, step assertions, and step variable extraction), `tcp_connect`, `tls_handshake` (`leaf_days_remaining`), and `dns_lookup` inside `declarative-check-runner`
- [ ] 3.3 Wire `DeclarativeCheckAssignmentCompiler` to compile Edge-only and Hybrid Edge subgraphs into agent plugin assignments with host/port allowlists and `SecretBroker` (`CredentialBrokerGrant`) credential injection
- [ ] 3.4 Persist `declarative-check-runner` `serviceradar.plugin_result.v1` verdicts and synthetic step waterfalls through agent `RecordSpool` -> gateway -> NATS JetStream -> Core ingestion into `DeclarativeCheckEdgeObservation`, `DeclarativeCheckInstance`, and `ServiceState`
- [ ] 3.5 Implement bounded ephemeral `TestDeclarativeCheck` execution path (`DeclarativeChecks.TestRunner`) returning redacted per-node inputs, extracted values, timings, and final verdict without mutating `ServiceState` or firing alerts

## 4. REST/JSON Import-Export API and SRQL Surface

- [ ] 4.1 Expose `/api/v2/declarative-checks` CRUD routes plus `GET /api/v2/declarative-checks/:slug/export` (deterministic secret-free canonical JSON) and `POST /api/v2/declarative-checks/import` (schema + secret-guard validation, `dry_run`, managed fingerprint reconciliation)
- [ ] 4.2 Update `ServiceRadarWebNGWeb.Api.OpenApiV2Controller` and regenerate `elixir/web-ng/priv/static/openapi.json` so OpenAPI drift checks pass
- [ ] 4.3 Extend `rust/srql` translator, AshAdapter, and `srql_catalog_controller.ex` with `in:declarative_check_results` and `declarative.<slug>` / `declarative.<slug>.status` filters

## 5. Two-Way Visual Pipeline Canvas Builder (`elixir/web-ng`)

- [ ] 5.1 Add `@blueprintjs/core`, `@blueprintjs/icons`, `@blueprintjs/select`, and `@xyflow/react` to `elixir/web-ng/assets/component/package.json` (`sfw` package-manager workflow) with `.sr-bp6-scope` CSS scoping, `.bp6-dark` theme sync, and scoped `portalContainer` isolation
- [ ] 5.2 Implement `DeclarativeCheckBuilderCanvas.jsx` and `DeclarativeCheckCanvasHook.js` with `@xyflow/react` node palette/canvas, `elkjs` layered auto-layout, Blueprint v6 property inspector drawer, `credential_slots` binder UI, and bidirectional live sync with `Monaco` JSON tab
- [ ] 5.3 Add the four 1-click starter graph templates (`"HTTP JSON API Check"`, `"SRQL Posture Check"`, `"Multi-Step Synthetic Journey"`, `"Multi-Vantage Composite Check"`) and interactive **Test Run** node trace overlay
- [ ] 5.4 Build `DeclarativeCheckLive.Index` (`/settings/declarative-checks`) and `DeclarativeCheckLive.Edit` (`/settings/declarative-checks/:slug`), plus "Clone as Declarative Check" actions on legacy `ServiceCheck` and `CompositeCheck` detail views and credential usage deep-links in Settings > Credentials
- [ ] 5.5 Write Vitest unit tests (including Blueprint CSS/portal isolation and Canvas <-> Monaco round-trip sync), ExUnit Core/Web-NG tests (covering all four PR `#6760` posture evaluators, secret-free export/import guards, hybrid `decision_table` staleness, and legacy import parity), and Playwright end-to-end builder verification
