# Change: Add declarative service and posture checks with visual DAG builder

## Why

ServiceRadar currently splits active monitoring, derived multi-signal verdicts, and control-plane posture checks across disconnected mechanisms: flat single-probe `ServiceRadar.Monitoring.ServiceCheck` rows, device-only `ServiceRadar.CompositeChecks.CompositeCheck` decision tables, bespoke Elixir health workers, and per-capability WASM plugin configurations. Operators cannot author, preview, export, or version-control a unified check pipeline -- whether checking an external HTTPS JSON API, running a multi-step synthetic journey, combining Edge probes with Core SRQL signals, or asserting PR #6760 SaaS Storage Entitlement and NVR continuous-recording posture -- without writing custom Elixir or WASM code.

Introducing a canonical, secret-free JSONB DAG check model (`platform.declarative_checks`) paired with a two-way Blueprint v6 + `@xyflow/react` + `elkjs` + `Monaco` visual pipeline builder, safe typed Core and Edge execution runners, and Built-in Pack #1 for Storage Entitlements and NVR Recording Health turns checks into portable, inspectable data that composes directly with Solution Packs (`add-solution-packs-and-git-catalog`).

## What Changes

- **Canonical Secret-Free JSONB Check Model in CNPG (`serviceradar_core`, schema `platform`)**:
  - Add `ServiceRadar.DeclarativeChecks.DeclarativeCheck` (`platform.declarative_checks`) storing a versioned, secret-free canonical DAG document (`schema_version: 1`, `slug`, `name`, `description`, `state`, `schedule`, `target_binding`, `inputs`, `credential_slots`, `nodes`, `edges`, `alert_policy`, optional `ui_layout`) alongside Solution Pack provenance and managed-reconciliation metadata (`pack_id`, `pack_version`, `managed`, `template_fingerprint`, `parameter_overrides`).
  - Add `ServiceRadar.DeclarativeChecks.DeclarativeCheckCredentialBinding` (`platform.declarative_check_credential_bindings`) mapping abstract `credential_slots` (`slot`, `provider`, `role`, `purpose`, `required`) to `platform.network_credential_secrets` or `platform.network_credential_rules` with restrictive foreign keys, guarded deletion via `ServiceRadar.Credentials.CredentialUsage`, and runtime grant issuance through `ServiceRadar.Credentials.SecretBroker` (`CredentialBrokerGrant`).
  - Add `ServiceRadar.DeclarativeChecks.DeclarativeCheckInstance` (`platform.declarative_check_instances`) materializing per-target verdicts (`healthy` | `degraded` | `down` | `unknown`), bounded redacted node snapshots, and transitions, projecting current availability and status into `ServiceRadar.Observability.ServiceState` (`platform.service_state`).
  - Add deterministic REST/JSON export and validated import endpoints (`GET /api/v2/declarative-checks/:slug/export` and `POST /api/v2/declarative-checks/import`) plus Ash JSON:API routes and OpenAPI spec coverage, enforcing strict v1 JSON Schema validation and hard secret-free guards.

- **Two-Way Visual Pipeline Canvas Builder (`elixir/web-ng`)**:
  - Add `/settings/declarative-checks` (index, import/export, pack badges, verdict rollups) and `/settings/declarative-checks/:slug` (visual builder + Monaco JSON editor + interactive Test Run).
  - Mount a React 19 component (`DeclarativeCheckBuilderCanvas.jsx` in `elixir/web-ng/assets/component/src/`) using Palantir Blueprint v6 chrome (`@blueprintjs/core`, `@blueprintjs/icons`, `@blueprintjs/select`) isolated inside a scoped `.sr-bp6-scope` container (`.bp6-dark` theme sync + scoped `portalContainer` so Blueprint styles never reset Tailwind v4 / daisyUI chrome), `@xyflow/react` drag-and-drop node/wire canvas, `elkjs` layered auto-layout, and a right-hand Blueprint property inspector drawer.
  - Provide bidirectional live synchronization with a `Monaco` JSON tab (editing the visual graph updates canonical JSON immediately; editing Monaco JSON validates against the v1 schema and updates the canvas).
  - Ship four 1-click starter graphs (`"HTTP JSON API Check"`, `"SRQL Posture Check"`, `"Multi-Step Synthetic Journey"`, `"Multi-Vantage Composite Check"`) and an interactive **Test Run** action that executes the graph on demand and renders live node-by-node resolved inputs (with secrets redacted), extracted fields, execution timings, and final verdict before saving.

- **Unified Singleton and Dynamic Target Fan-Out**:
  - Support `target_binding` modes `singleton` (deployment-wide posture or single static endpoint), `srql_devices` (`in:devices ...` dynamic device population with paged evaluation, DIRE device merge reassignment, and scope departure cleanup), and `service_targets` (standalone or device-linked service endpoints from `add-service-oriented-plugin-monitoring`), with safe template variable interpolation and per-target credential-rule resolution.

- **Safe Typed Node Families and Two Execution Runners (Zero Arbitrary User Code or Raw SQL)**:
  - **Core Signal Nodes** (executed in `serviceradar_core` via Oban schedules, zero WASM):
    - `srql_query`: bounded read-only SRQL query routed exclusively through the SRQL AshAdapter with strict row and timeout caps.
    - `platform_posture`: closed registry of first-party Core evaluators shipping **Built-in Pack #1 (`io.serviceradar.storage-and-nvr-health`) for PR #6760 Storage Entitlements and NVR Recording Health**:
      1. `storage.entitlement_utilization` (`billable_bytes / plan_bytes`, warn `85%`, crit `95%`, down `>= 100%` or `hard_cap_active`).
      2. `storage.hold_pin_pressure` (`held_bytes` share of archive budget warning when `PD5` hold pins starve normal retention).
      3. `storage.archive_credential_and_usage_health` (`:local_and_archive` policies with missing or failing `:uploader`/`:writer`, `:reader`, or `:retention` secrets, or `StorageUsageDailyReport` stale `> 36h`).
      4. `camera.continuous_recording_silence` (enabled `continuous` `CameraRecordingPolicy` with `0` sealed `RecordingCatalogEntry` blocks over `silence_window_minutes`, default `15`).
  - **Edge Signal Nodes** (compiled into agent plugin assignments targeting ONE shipped first-party generic `declarative-check-runner` WASM plugin on `serviceradar-agent`):
    - `http_request` and `http_journey` (composing with `add-wasm-synthetic-journey-sdk` `httptrace` phase waterfalls, status/header/body/JSONPath assertions, `SecretBroker` credential injection, and `RecordSpool` -> NATS JetStream durable delivery), `tcp_connect`, `tls_handshake` (including `leaf_days_remaining`), and `dns_lookup`.
  - **Transform, Assertion, and Verdict Nodes**:
    - `extract_field` (safe JSONPath subset, HTTP header, bounded linear-time regex, SRQL column), `threshold_assert` (`warn` / `crit` numeric, string, and boolean comparators), `decision_table` (generalizing `CompositeCheck` with per-input `max_age_seconds` staleness -> `unknown` and a mandatory all-`*` catch-all row, enabling hybrid Edge + Core signal graphs), and `alert_output` -> `ServiceState` + OCSF `health.state_change` event via JetStream + `StatefulAlertRule` incident promotion.

- **Non-Breaking Coexistence and 1-Click Legacy Import Adapters**:
  - Preserve existing `ServiceRadar.Monitoring.ServiceCheck` and `ServiceRadar.CompositeChecks.CompositeCheck` resources, workers, and SRQL fields untouched (**BREAKING**: none).
  - Add pure 1-click conversion adapters (`LegacyImporter.from_service_check/1` and `LegacyImporter.from_composite_check/1`) in UI and API so operators can clone legacy checks into draft `DeclarativeCheck` DAGs, test-run them, and cut over without dual-alerting.

## Impact

- **Affected specs**:
  - `declarative-service-checks` (new capability)
  - `build-web-ui` (visual DAG builder, Blueprint v6 scoping, starter templates, Test Run, import/export, legacy clone UI)
  - `wasm-plugin-system` (`declarative-check-runner` first-party WASM plugin, Edge subgraph assignment compilation, `SecretBroker` injection, `httptrace` and `RecordSpool` integration)
- **Related changes**:
  - `add-solution-packs-and-git-catalog` (consumes canonical `DeclarativeCheck` JSON documents and shares `credential_slots`, `pack_id`, `pack_version`, `managed`, `template_fingerprint`, and `parameter_overrides` contracts)
  - `add-composite-service-checks` (coexists non-breakingly; `decision_table` generalizes its pure verdict semantics and offers 1-click import)
  - `add-service-oriented-plugin-monitoring` (`service_targets` fan-out mode and `SecretBroker` service monitoring consumer kind)
  - `add-wasm-synthetic-journey-sdk` (`httptrace` waterfall timing phases and `RecordSpool` durable edge delivery reused by `declarative-check-runner`)
- **Affected code**:
  - `elixir/serviceradar_core/lib/serviceradar/declarative_checks/**` (Ash domain, resources, canonical JSON validator/formatter, DAG evaluator, Oban scheduler/workers, posture evaluators for `#6760`, Edge assignment compiler, legacy import adapters, DIRE merge hook)
  - `elixir/serviceradar_core/lib/serviceradar/credentials/credential_usage.ex` and deletion/lifecycle guards
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/declarative_checks_live/**` and `controllers/api/declarative_check_controller.ex`
  - `elixir/web-ng/assets/component/src/DeclarativeCheckBuilderCanvas.jsx` and `elixir/web-ng/assets/js/hooks/DeclarativeCheckCanvasHook.js`
  - `go/cmd/wasm-plugins/declarative-check-runner/**` or `rust/wasm-plugins/declarative-check-runner/**` + Bazel `UploadSignature` packaging
  - `rust/srql/**` (SRQL `in:declarative_check_results` and `declarative.<slug>` device/service filters)

## Non-Goals

- **No arbitrary code or raw SQL execution**: Checks NEVER evaluate user-supplied JavaScript, Lua, Starlark, shell commands, Elixir MFA tuples, or raw SQL strings. Every node is a closed, schema-validated typed operator.
- **No secrets in check JSON**: Plaintext or ciphertext credentials, bearer tokens, S3 keys, and deployment-specific `credential_secret_id` UUIDs NEVER appear in exported check JSON or Solution Pack files.
- **No forced migration or removal of `ServiceCheck` or `CompositeCheck`**: Existing checks continue running unchanged; migration is opt-in via 1-click draft import.
- **No full headless Chromium browser runtime on `serviceradar-agent`**: Synthetic HTTP journeys execute via the lightweight WASI `declarative-check-runner` HTTP/TLS/DNS host capabilities, not a headless browser container.
