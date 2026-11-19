# declarative-service-checks Specification

## Purpose
Versioned, secret-free declarative service and posture checks modeled as canonical JSONB DAGs with brokered credential slots, unified singleton and dynamic target fan-out, safe Core signal and posture evaluators, deterministic REST JSON import/export, and non-breaking legacy check import adapters.

## Requirements
### Requirement: Canonical Secret-Free Declarative Check Document Model
The system SHALL persist every declarative check in CNPG (`platform.declarative_checks`) as a versioned (`schema_version: 1`), secret-free JSONB Directed Acyclic Graph (DAG) containing `slug`, `name`, `state`, `schedule`, `target_binding`, `inputs`, `credential_slots`, `nodes`, `edges`, `alert_policy`, optional `ui_layout`, and Solution Pack lifecycle fields (`pack_id`, `pack_version`, `managed`, `template_fingerprint`, `parameter_overrides`).

The system MUST validate that `nodes` and `edges` form a finite, type-compatible, acyclic graph (`<= 64` nodes, `<= 128` edges) terminating in at least one `alert_output` node, and MUST reject unknown top-level or node-config fields.

#### Scenario: Valid declarative check DAG is persisted with canonical template fingerprint
- **GIVEN** an operator submits a `schema_version: 1` declarative check with valid `slug`, `schedule`, `target_binding`, `inputs`, `credential_slots`, `nodes`, `edges`, and `alert_policy`
- **WHEN** `ServiceRadar.DeclarativeChecks.DeclarativeCheck` validates and creates the record
- **THEN** the check SHALL be stored in `platform.declarative_checks`
- **AND** `template_fingerprint` SHALL be computed as the deterministic lowercase SHA-256 hex digest of the canonical semantic fields excluding `ui_layout`, `state`, and `parameter_overrides`

#### Scenario: Cyclic or untyped graph is rejected at validation
- **GIVEN** a declarative check payload whose `edges` introduce a cycle between two nodes or connect incompatible handle types
- **WHEN** validation runs during create, update, or import
- **THEN** the system SHALL reject the document with a structured validation error naming the offending node or edge IDs

#### Scenario: Parameter overrides and layout changes preserve managed template fingerprint
- **GIVEN** a `managed: true` check installed with `pack_id: "io.serviceradar.storage-and-nvr-health"` and `pack_version: "1.0.0"`
- **WHEN** an operator updates `parameter_overrides` (for example setting `warn_percent` to `80.0`) or drags nodes in `ui_layout`
- **THEN** `template_fingerprint` and `managed: true` SHALL remain unchanged so future Solution Pack upgrades reconcile cleanly
- **AND** modifying `nodes` or `edges` structurally SHALL require explicit operator confirmation to detach (`managed: false`)

### Requirement: Secret-Free Credential Slots and Brokered Resolution
Declarative check JSON documents MUST NEVER contain plaintext or ciphertext credentials, bearer tokens, API keys, S3 secret keys, or deployment-local `credential_secret_id` UUIDs; instead, checks SHALL declare abstract `credential_slots` (`slot`, `provider`, `role`, `purpose`, `required`) bound locally via `platform.declarative_check_credential_bindings` to `platform.network_credential_secrets` or `platform.network_credential_rules` and resolved exclusively through `ServiceRadar.Credentials.SecretBroker` (`CredentialBrokerGrant`).

Each local binding row MUST enforce restrictive foreign keys (`on_delete: :restrict`) and register in `ServiceRadar.Credentials.CredentialUsage` so in-use credentials and rules cannot be silently deleted.

#### Scenario: Check binds abstract credential slot to CNPG secret and resolves via SecretBroker
- **GIVEN** a declarative check declaring `credential_slots: [{"slot": "api_auth", "provider": "http_bearer", "role": "reader", "purpose": "synthetic_http", "required": true}]`
- **AND** an operator binds `"api_auth"` to a secret in `platform.network_credential_secrets`
- **WHEN** the check is compiled or executed for `https://api.example.com/v1/health`
- **THEN** the system SHALL issue an endpoint-locked `CredentialBrokerGrant` via `SecretBroker`
- **AND** the secret material SHALL NOT appear in `platform.declarative_checks`, agent config JSON, `node_snapshots`, or logs

#### Scenario: Guarded deletion blocks removing a bound credential secret
- **GIVEN** a credential secret in `platform.network_credential_secrets` bound to an existing declarative check via `platform.declarative_check_credential_bindings`
- **WHEN** an administrator attempts to delete that credential secret
- **THEN** guarded deletion SHALL block the destroy operation and list the referencing declarative check in credential usage

### Requirement: Deterministic REST JSON Export and Validated Import
The system SHALL expose `GET /api/v2/declarative-checks/:slug/export` and `POST /api/v2/declarative-checks/import` to export and import canonical `schema_version: 1` check JSON documents with deterministic key ordering and strict secret-free preflight validation.

#### Scenario: Exporting a check produces deterministic secret-free JSON
- **GIVEN** an enabled declarative check `"checkout-api-health"` with bound local credentials in `platform.declarative_check_credential_bindings`
- **WHEN** an authorized caller requests `GET /api/v2/declarative-checks/checkout-api-health/export`
- **THEN** the endpoint SHALL return HTTP 200 with deterministic canonical JSON containing `credential_slots`
- **AND** the payload SHALL omit deployment-local UUIDs, `credential_secret_id`, `credential_rule_id`, and any secret values

#### Scenario: Importing a check rejects embedded secrets
- **GIVEN** an import payload sent to `POST /api/v2/declarative-checks/import` containing a raw `password`, `secret_access_key`, `credential_secret_id`, or literal `Authorization: Bearer` secret value
- **WHEN** the import preflight validator inspects the document
- **THEN** the endpoint SHALL reject the request with HTTP 422 and a secret-guard diagnostic without persisting any data

### Requirement: Unified Singleton and Dynamic Target Fan-Out
The system SHALL support `target_binding` modes `singleton`, `srql_devices` (`in:devices ...`), and `service_targets`, materializing per-target verdicts (`healthy` | `degraded` | `down` | `unknown`) in `platform.declarative_check_instances` and projecting current availability into `platform.service_state` (`ServiceRadar.Observability.ServiceState`).

#### Scenario: Dynamic SRQL device fan-out evaluates per target and prunes departed devices
- **GIVEN** an enabled declarative check with `target_binding: {"mode": "srql_devices", "scope_query": "in:devices tags.role:edge-gateway"}` matching two synthetic devices `dev-1` (`192.0.2.10`) and `dev-2` (`192.0.2.11`)
- **WHEN** the scheduled evaluation pass runs and later `dev-2` loses the `edge-gateway` tag
- **THEN** the first pass SHALL materialize per-device `DeclarativeCheckInstance` and `ServiceState` verdicts for `dev-1` and `dev-2` with safe `{{target.*}}` interpolation and per-device credential-rule matching
- **AND** the subsequent pass SHALL prune `dev-2` from `platform.declarative_check_instances` and mark its `ServiceState` projection `"inactive"`

#### Scenario: DIRE device merge reassigns declarative check instances
- **GIVEN** a `DeclarativeCheckInstance` recorded for `device_uid: "sr:loser-0001"`
- **WHEN** DIRE merges `"sr:loser-0001"` into `"sr:winner-0001"`
- **THEN** `DeclarativeCheckInstance.reassign_device/2` SHALL re-key or deduplicate the instance onto `"sr:winner-0001"` without leaving orphaned rows

### Requirement: Safe Core Signal Nodes and Built-In PR #6760 Storage and NVR Posture Evaluators
The system SHALL execute Core-only signal nodes (`srql_query` and `platform_posture`) directly in `serviceradar_core` on scheduled Oban jobs without WASM overhead, raw SQL execution, or arbitrary user code, and SHALL ship Built-in Pack #1 (`io.serviceradar.storage-and-nvr-health`) implementing four first-party posture evaluators for PR `#6760`: `storage.entitlement_utilization`, `storage.hold_pin_pressure`, `storage.archive_credential_and_usage_health`, and `camera.continuous_recording_silence`.

#### Scenario: SRQL query node enforces read-only AshAdapter bounds
- **GIVEN** a Core declarative check containing an `srql_query` node
- **WHEN** `CoreEvaluationWorker` executes the node
- **THEN** the query SHALL route exclusively through the SRQL AshAdapter with bounded `limit <= 1000` and `timeout_ms <= 10000`
- **AND** any malformed or non-read query SHALL fail validation without executing raw SQL

#### Scenario: Storage entitlement utilization evaluator detects warning, critical, and hard-cap states
- **GIVEN** a hosted deployment with applied `StorageEntitlement` `allocation_bytes` (`plan_bytes`) and active recordings usage (`billable_bytes`)
- **WHEN** `platform_posture` runs `storage.entitlement_utilization`
- **THEN** the check SHALL report `degraded` at `>= 85%` utilization, `down` at `>= 95%` utilization, and `down` immediately when `utilization_percent >= 100%` or `hard_cap_active` is true

#### Scenario: Hold pin pressure evaluator warns when PD5 holds starve normal retention
- **GIVEN** active `:accepted` `RecordingHold` pins (`PD5` `held_bytes`) consuming archive budget above the configured warning share
- **WHEN** `platform_posture` runs `storage.hold_pin_pressure`
- **THEN** the evaluator SHALL emit `held_bytes`, `held_share_percent`, and `projected_cutoff_days`, transitioning the check verdict to `degraded` or `down` per configured thresholds

#### Scenario: Archive credential and usage health evaluator detects missing secrets or stale daily reports
- **GIVEN** an enabled `:local_and_archive` recording configuration where any `:writer` (`:uploader`), `:reader`, or `:retention` secret in `platform.network_credential_secrets` is missing/failing OR the latest `StorageUsageDailyReport` is older than `36` hours
- **WHEN** `platform_posture` runs `storage.archive_credential_and_usage_health`
- **THEN** the check SHALL transition to an unhealthy verdict (`degraded` or `down`) identifying the unhealthy role or stale usage report age without exposing secret material

#### Scenario: Continuous recording silence evaluator detects stalled camera recording policies
- **GIVEN** an enabled `CameraRecordingPolicy` with `mode == :continuous` (while recording control is not operator-suspended) that seals `0` non-quarantined `RecordingCatalogEntry` blocks across `silence_window_minutes` (default `15` minutes)
- **WHEN** `platform_posture` runs `camera.continuous_recording_silence`
- **THEN** the check SHALL transition to `down` and report the silent policy count

### Requirement: Safe Transform, Assertion, Hybrid Decision Table, and Alert Output Nodes
The system SHALL evaluate `extract_field`, `threshold_assert`, `decision_table`, and `alert_output` nodes deterministically using a pure evaluation engine shared across Core execution, Edge execution, and interactive Test Runs, without permitting arbitrary scripts or catastrophic-backtracking regexes.

#### Scenario: Hybrid Edge and Core decision table enforces max_age_seconds staleness and mandatory catch-all
- **GIVEN** a declarative check combining an Edge `http_request` observation (`max_age_seconds: 300`) and a Core `srql_query` signal into a `decision_table` node
- **WHEN** the Edge observation is `420` seconds old
- **THEN** `decision_table` SHALL coerce that stale input to `"unknown"`, evaluate rows in order using first-match-wins semantics, fall through to the mandatory all-`*` catch-all row if no earlier row matches, and emit the resulting verdict

#### Scenario: Alert output publishes OCSF health.state_change to JetStream and promotes StatefulAlertRule incidents
- **GIVEN** an enabled declarative check with `alert_policy.emit_ocsf_transition: true` whose target verdict transitions from `healthy` to `down`
- **WHEN** `alert_output` commits the transition
- **THEN** `DeclarativeCheckInstance` and `ServiceState` SHALL update in CNPG
- **AND** `VerdictEventWriter` SHALL publish an OCSF `health.state_change` event to NATS JetStream (`OcsfEventPublisher`) for `EventWriter` storage and `StatefulAlertRule` incident promotion

### Requirement: Non-Breaking Legacy Coexistence and 1-Click Import Adapters
The system SHALL preserve existing `ServiceRadar.Monitoring.ServiceCheck` and `ServiceRadar.CompositeChecks.CompositeCheck` execution non-breakingly while providing deterministic 1-click import adapters (`LegacyImporter.from_service_check/1` and `LegacyImporter.from_composite_check/1`) that convert legacy checks into `state: "draft"` `DeclarativeCheck` DAGs.

#### Scenario: Cloning a legacy CompositeCheck creates an equivalent draft DeclarativeCheck DAG
- **GIVEN** an existing `CompositeCheck` with two `vantage_point` inputs, one `device_metadata` input, and ordered `CompositeCheckRule` rows
- **WHEN** an operator invokes 1-click import (`from_composite_check/1`)
- **THEN** the system SHALL create a valid `schema_version: 1` `DeclarativeCheck` in `state: "draft"` with an equivalent `srql_devices` `target_binding`, `decision_table` node, and `alert_output` node
- **AND** the original `CompositeCheck` SHALL remain unchanged so no duplicate alerts fire during evaluation preview

