# Design: Declarative Service and Posture Checks

## Context

ServiceRadar operators today configure monitoring across several specialized models:
1. `ServiceRadar.Monitoring.ServiceCheck` (`platform.service_checks`) handles flat, single-step polling checks (`:ping`, `:http`, `:tcp`, `:dns`, `:grpc`) tied to one target and one static latency threshold.
2. `ServiceRadar.CompositeChecks.CompositeCheck` (`platform.composite_checks`) derives device-scoped verdicts over existing sweep availability (`vantage_point`) and `device_metadata` signals using an ordered decision table, without dispatching probes or supporting standalone URLs/services.
3. PR `#6760` introduced SaaS Storage Entitlements (`ServiceRadar.Storage.StorageEntitlements`), closed-day usage reports (`ServiceRadar.Storage.StorageUsageDailyReport`), `PD5` recording holds (`ServiceRadar.Camera.RecordingHolds`), Cloud archive credential slots (`ServiceRadar.Camera.CloudArchiveCredentials`), and continuous NVR policies (`ServiceRadar.Camera.CameraRecordingPolicy` + `RecordingCatalogEntry`), all of which require first-class posture monitoring and alerting without hardcoding opaque background pollers.
4. `add-solution-packs-and-git-catalog` introduces `.srpack` archives and two-way GitOps catalogs that package checks, alert rules, and dashboards together as portable, secret-free JSON artifacts.

To unify active synthetic checks, multi-vantage composite checks, SRQL queries, and control-plane posture checks into a single inspectable, Git-friendly abstraction -- without allowing arbitrary code execution or leaking secrets -- every check must be represented canonically as a typed JSONB Directed Acyclic Graph (DAG).

## Goals / Non-Goals

- **Goals**:
  - Represent every declarative check canonically in CNPG (`platform.declarative_checks`) as a versioned (`schema_version: 1`), deterministic, secret-free JSONB DAG that round-trips losslessly between REST export/import, Solution Packs, Monaco JSON editing, and the visual canvas.
  - Provide an ergonomic two-way visual DAG builder in `web-ng` combining Palantir Blueprint v6 chrome (strictly CSS-scoped), `@xyflow/react`, `elkjs` auto-layout, `Monaco` JSON editing, 1-click starter graphs, and an interactive node-by-node **Test Run** inspector.
  - Support `singleton`, `srql_devices`, and `service_targets` target bindings under one uniform `DeclarativeCheckInstance` -> `ServiceState` verdict projection.
  - Execute Core-only graphs directly in `serviceradar_core` via Oban (zero WASM overhead) and compile Edge subgraphs into assignments for a single first-party `declarative-check-runner` WASM plugin on `serviceradar-agent`, enabling hybrid Edge + Core graphs via `decision_table`.
  - Ship Built-in Pack #1 (`io.serviceradar.storage-and-nvr-health`) covering all four PR `#6760` Storage Entitlement and NVR Recording Health posture evaluators out of the box.
  - Coexist non-breakingly with `ServiceCheck` and `CompositeCheck` while providing deterministic 1-click import adapters.

- **Non-Goals**:
  - Executing user-authored scripts (`eval`, JS, Lua, Python, raw SQL, shell) in Core, `web-ng`, or `serviceradar-agent`.
  - Embedding credential secrets or environment-local secret UUIDs inside portable check JSON documents.
  - Modifying CNPG vs StarRocks telemetry routing laws: all check transition events and synthetic probe telemetry continue to publish to NATS JetStream first and persist via `EventWriter`.
  - Replacing high-rate network sweepers (`sweep-jobs`) with per-device WASM plugin invocations.

## Decisions

### Decision 1: Canonical Secret-Free JSONB Document and Pack Provenance Contract

Every check is stored in `platform.declarative_checks` (`ServiceRadar.DeclarativeChecks.DeclarativeCheck`) and exports to a canonical JSON document with `schema_version: 1`:

```json
{
  "schema_version": 1,
  "slug": "storage-entitlement-utilization",
  "name": "Storage Entitlement Utilization",
  "description": "Monitors SaaS recordings entitlement utilization and hard-cap state.",
  "state": "enabled",
  "pack_id": "io.serviceradar.storage-and-nvr-health",
  "pack_version": "1.0.0",
  "managed": true,
  "template_fingerprint": "0000000000000000000000000000000000000000000000000000000000000001",
  "parameter_overrides": {},
  "schedule": {
    "interval_seconds": 300,
    "timeout_seconds": 30,
    "jitter_seconds": 15
  },
  "target_binding": {
    "mode": "singleton"
  },
  "inputs": [
    {
      "key": "warn_percent",
      "type": "number",
      "default": 85.0,
      "min": 1.0,
      "max": 100.0,
      "description": "Warning utilization percentage"
    },
    {
      "key": "crit_percent",
      "type": "number",
      "default": 95.0,
      "min": 1.0,
      "max": 100.0,
      "description": "Critical utilization percentage"
    }
  ],
  "credential_slots": [],
  "nodes": [
    {
      "id": "posture_1",
      "kind": "platform_posture",
      "label": "Entitlement Utilization",
      "config": {
        "evaluator": "storage.entitlement_utilization",
        "consumer": "recordings"
      }
    },
    {
      "id": "assert_util",
      "kind": "threshold_assert",
      "label": "Utilization Thresholds",
      "config": {
        "field": "utilization_percent",
        "warn": { "op": ">=", "value": "{{inputs.warn_percent}}" },
        "crit": { "op": ">=", "value": "{{inputs.crit_percent}}" },
        "fail_closed_field": "hard_cap_active"
      }
    },
    {
      "id": "out_1",
      "kind": "alert_output",
      "label": "Storage Entitlement Verdict",
      "config": {
        "verdict_map": {
          "healthy": "within_entitlement",
          "degraded": "approaching_entitlement_cap",
          "down": "entitlement_cap_exceeded",
          "unknown": "entitlement_unconfigured"
        }
      }
    }
  ],
  "edges": [
    {
      "id": "e1",
      "source": "posture_1",
      "source_handle": "signal",
      "target": "assert_util",
      "target_handle": "in"
    },
    {
      "id": "e2",
      "source": "assert_util",
      "source_handle": "verdict",
      "target": "out_1",
      "target_handle": "in"
    }
  ],
  "alert_policy": {
    "emit_ocsf_transition": true,
    "open_on_statuses": ["down"],
    "priority": 2,
    "threshold": 1,
    "window_seconds": 300,
    "cooldown_seconds": 300,
    "renotify_seconds": 21600
  },
  "ui_layout": {
    "nodes": {
      "posture_1": { "x": 80, "y": 120 },
      "assert_util": { "x": 380, "y": 120 },
      "out_1": { "x": 680, "y": 120 }
    }
  }
}
```

**Why this structure**:
- **Shared Solution Pack contract**: `credential_slots`, `pack_id`, `pack_version`, `managed`, `template_fingerprint`, and `parameter_overrides` match `add-solution-packs-and-git-catalog` field-for-field, modeled directly on `ServiceRadar.Observability.RuleSeeder` (`managed` + `template_fingerprint`).
- **Fingerprint stability across UI layout and parameter tuning**: `template_fingerprint` is computed as the lowercase SHA-256 hex digest of deterministic canonical JSON (RFC 8785 JCS sorted keys, reusing the `ArchiveCanonicalJSON` encoding pattern) over the semantic template fields (`schema_version`, `slug`, `schedule`, `target_binding`, `inputs`, `credential_slots`, `nodes`, `edges`, `alert_policy`), excluding `ui_layout`, `state`, and `parameter_overrides`. Operators can tune `parameter_overrides` (for example changing `warn_percent` from `85` to `80`) or reposition nodes without breaking `managed: true` pack upgrade reconciliation. Structural edits to `nodes` or `edges` on a `managed: true` check require explicit operator confirmation to detach (`managed: false`).
- **Hard secret-free separation**: Checks declare abstract `credential_slots` (`[{slot, provider, role, purpose, required}]`). Deployment-local bindings live in a dedicated Ash resource `ServiceRadar.DeclarativeChecks.DeclarativeCheckCredentialBinding` (`platform.declarative_check_credential_bindings`) with `on_delete: :restrict` foreign keys to `platform.network_credential_secrets` and `platform.network_credential_rules`, registered in `ServiceRadar.Credentials.CredentialUsage` and `GuardCredentialDestroy`. Export (`GET /api/v2/declarative-checks/:slug/export`) never serializes binding IDs or secret material, and import (`POST /api/v2/declarative-checks/import`) runs a secret-free preflight validator that rejects unknown keys and secret-shaped fields (`password`, `secret`, `token`, `private_key`, `access_key_id`, `secret_access_key`, `credential_secret_id`, literal `Authorization: Bearer ...` headers).

### Decision 2: Blueprint v6 + `@xyflow/react` + `elkjs` + `Monaco` Visual Canvas with Strict CSS Isolation

The visual builder is implemented as a mounted React 19 component (`elixir/web-ng/assets/component/src/DeclarativeCheckBuilderCanvas.jsx`) bridged to Phoenix LiveView (`DeclarativeCheckLive.Edit`) via `DeclarativeCheckCanvasHook`:

1. **CSS Isolation for Blueprint v6 inside Tailwind v4 / daisyUI**:
   - Importing `@blueprintjs/core/lib/css/blueprint.css` globally would apply document-wide resets (`body`, `a`, `p`, box-sizing, focus rings) that collide with Tailwind v4 and daisyUI across `web-ng`.
   - Instead, Blueprint CSS rules are PostCSS/Tailwind-scoped under `.sr-bp6-scope` (with `.bp6-dark` toggled automatically on `.sr-bp6-scope` whenever ServiceRadar's active theme is dark), and a dedicated `<div class="sr-bp6-scope sr-bp6-portal-root" ref={portalRef} />` inside the builder mount serves as `portalContainer` for every Blueprint `Overlay2`, `Drawer`, `Popover`, `Menu`, and `Select`. Zero Blueprint styles or portals escape outside the builder subtree.
2. **Two-Way Live Sync (`Canvas <-> Canonical AST <-> Monaco`)**:
   - Both the `@xyflow/react` canvas + Blueprint property inspector and the `Monaco` JSON tab read and dispatch against a single canonical check document state in React (synced to LiveView for server-side Ash/DAG validation and persistence).
   - Canvas mutations update `nodes`, `edges`, `inputs`, `credential_slots`, and `ui_layout` immediately, formatting deterministic 2-space canonical JSON into the Monaco model without resetting undo history when Monaco is unfocused.
   - Monaco edits debounce (`150ms`), validate against the bundled v1 JSON Schema (rendering inline Monaco squiggles on syntax, schema, cycle, or secret-guard errors), and update the `@xyflow/react` graph once valid. Any node added in JSON without `ui_layout.nodes[id]` coordinates receives deterministic coordinates via `elkjs` (`layered` algorithm, `elk.direction = "RIGHT"`).
3. **1-Click Starter Graphs and Interactive Test Run**:
   - Empty checks offer four 1-click starter templates: `"HTTP JSON API Check"`, `"SRQL Posture Check"`, `"Multi-Step Synthetic Journey"`, and `"Multi-Vantage Composite Check"`.
   - Clicking **Test Run** invokes `DeclarativeChecks.TestRunner.run_ephemeral/3` (gated on `declarative_checks.evaluate` RBAC permission). Core nodes execute directly in a bounded sandbox task; Edge nodes execute either via an ephemeral on-demand `TestDeclarativeCheck` control-stream dispatch to the selected `serviceradar-agent`'s `declarative-check-runner` WASM plugin (15s hard timeout) or against latest cached observations for `decision_table` inputs. Results stream back to LiveView and decorate each `@xyflow/react` node with status badge, `duration_ms`, redacted resolved inputs (`"[REDACTED]"` for any `SecretBroker`-injected value), extracted values, and final verdict without mutating `ServiceState` or triggering `StatefulAlertRule` incidents.

### Decision 3: Unified Singleton and Dynamic Target Fan-Out (`DeclarativeCheckInstance` -> `ServiceState`)

A single `target_binding` contract handles both singleton posture checks and fleet-scale fan-out:

| `target_binding.mode` | Target Resolution | `target_key` Format | Example Use Case |
| --- | --- | --- | --- |
| `singleton` | Single evaluation context per schedule tick | `"singleton"` | `#6760` Storage Entitlement posture, `https://api.example.com/healthz` |
| `srql_devices` | Paged SRQL `in:devices ...` query (1,000/page via SRQL AshAdapter) | `"device:<device_uid>"` | TLS cert expiry or multi-vantage check across `in:devices tags.role:edge- firewall` |
| `service_targets` | Bound `ServiceTarget` records (IDs or tag/SRQL selector) | `"service:<service_target_id>"` | Multi-step synthetic HTTP login/API journeys across 200 SaaS/internal URLs |

- **Per-target interpolation and credential rules**: Node configs may reference `{{inputs.<key>}}` and safe target fields (`{{target.uid}}`, `{{target.ip}}`, `{{target.hostname}}`, `{{target.url}}`, `{{target.host}}`, `{{target.port}}`, `{{target.tags.<k>}}`). Interpolated values are strictly URL/host-validated before execution to prevent SSRF or host-header smuggling. For `srql_devices` and `service_targets`, `credential_slots` bound to `platform.network_credential_rules` dynamically select the highest-priority matching credential for each target and issue target-locked `CredentialBrokerGrant` records.
- **State projection and lifecycle**:
  - `platform.declarative_check_instances` (`primary_key: [:check_id, :target_key]`) stores `verdict`, `status` (`healthy` | `degraded` | `down` | `unknown`), `summary`, `node_snapshots` (bounded <= 16 KB redacted JSONB), `evaluated_at`, and `changed_at`.
  - Every instance upserts into `platform.service_state` (`service_type: "declarative_check"`, `service_name: "<slug>"` for singleton or `"<slug>/<target_key>"` for fan-out, `available: status == "healthy"`, structured verdict metadata in `details`), broadcasting via `ServiceStatePubSub`.
  - Devices leaving an `srql_devices` scope have their stale `DeclarativeCheckInstance` rows pruned and corresponding `ServiceState` rows deactivated (`state: "inactive"`). DIRE device merges reassign `device_uid` via `DeclarativeCheckInstance.reassign_device/2`, matching `DeviceCompositeCheckResult`.

### Decision 4: Two Execution Runners and Hybrid DAG Semantics

To avoid running WASM inside `serviceradar_core` while also avoiding custom WASM plugins per check, the DAG compiler classifies every check graph into one of three execution topologies:

1. **Core-Only Graph** (contains `srql_query` / `platform_posture` + transform/assert/decision/output nodes, zero Edge signal nodes):
   - Executed entirely in `serviceradar_core` by `ServiceRadar.DeclarativeChecks.CoreEvaluationWorker` on the `:declarative_checks` Oban queue. Zero WASM compilation or agent assignment is created.
2. **Edge-Only Graph** (contains Edge signal nodes `http_request` / `http_journey` / `tcp_connect` / `tls_handshake` / `dns_lookup` + local `extract_field` / `threshold_assert` / `decision_table` / `alert_output`, zero Core signal nodes):
   - `DeclarativeCheckAssignmentCompiler` compiles the Edge subgraph, target batch, host/port allowlist, and `CredentialBrokerGrant` references into a standard plugin assignment targeting the single shipped first-party `declarative-check-runner` WASM plugin (`plugin_id: "io.serviceradar.declarative-check-runner"`).
   - `serviceradar-agent` executes `declarative-check-runner` in its WASI sandbox: host functions inject brokered credentials (`SecretBroker`) only on allowlisted schemes/hosts/ports, collect `httptrace` phase waterfalls (`dns_ms`, `tcp_ms`, `tls_ms`, `ttfb_ms`, `transfer_ms`, `total_ms`), evaluate pure extraction/assertion nodes, and emit `serviceradar.plugin_result.v1` + structured synthetic step records through the agent's durable `RecordSpool` -> gateway -> NATS JetStream -> `EventWriter` / result ingestor, which updates `DeclarativeCheckInstance` and `ServiceState`.
3. **Hybrid Edge + Core Graph** (combines Edge signal nodes from one or more agent vantage points with Core `srql_query`, `platform_posture`, or `device_metadata` inputs feeding a `decision_table` -> `alert_output`):
   - `DeclarativeCheckAssignmentCompiler` compiles each Edge signal branch into a `declarative-check-runner` plugin assignment per designated `agent_id`, persisting per-(check, node, target, agent) signal observations as they arrive.
   - `CoreEvaluationWorker` (plus a debounced 30s event-driven refresh on new Edge signal ingestion, mirroring `CompositeChecks`) resolves the Core signal nodes, reads the latest Edge branch observations enforcing per-input `max_age_seconds` (stale -> `"unknown"`), runs the shared pure `DecisionTableEvaluator` (with mandatory all-`*` catch-all row), and writes the unified verdict to `DeclarativeCheckInstance` + `ServiceState`.

### Decision 5: Built-In Pack #1 (`io.serviceradar.storage-and-nvr-health`) for PR #6760

`ServiceRadar.DeclarativeChecks.PostureEvaluators` provides a closed compile-time map of evaluator slugs to pure/read-only Elixir modules. Built-in Pack #1 seeds four `managed: true` posture checks covering PR `#6760`:

1. **`storage.entitlement_utilization`**:
   - Reads `StorageEntitlements.effective_state/1` and latest recordings/warehouse usage metrics (`StorageUsageReports` / `RecordingCatalogEntry` active archive bytes).
   - Computes `billable_bytes`, `plan_bytes` (`allocation_bytes`), `hard_limit_bytes`, `utilization_percent = (billable_bytes / plan_bytes) * 100`, and `hard_cap_active` (`billable_bytes >= hard_limit_bytes` or `archive_jobs_hold_reason` due to entitlement cap).
   - Default thresholds: `warn >= 85%` (`degraded`), `crit >= 95%` (`down`), and immediate `down` when `utilization_percent >= 100%` or `hard_cap_active == true`. On self-hosted deployments (`hosted?: false`), evaluates against `RecordingArchiveSettings.object_budget_bytes` when `object_budget_mode == :limited`, or returns `healthy` (`mode: "unbounded_self_hosted"`).
2. **`storage.hold_pin_pressure`**:
   - Reads active `:accepted` `RecordingHold` pinned archive bytes (`PD5` `non_reapable_bytes`) against effective archive budget (`hard_limit_bytes` or `object_budget_bytes`) and `RetentionCalculator.calculate_object_retention/2`.
   - Emits `held_bytes`, `budget_bytes`, `held_share_percent`, `active_hold_count`, and `projected_cutoff_days`. Warns (`degraded` default `>= 50%`, `down` default `>= 80%`) when `PD5` hold pins starve normal `C3a` object retention.
3. **`storage.archive_credential_and_usage_health`**:
   - Checks whether `RecordingArchiveSettings.archive_enabled` is true or any `CameraRecordingPolicy` has `mode == :continuous` and `storage == :local_and_archive`.
   - Verifies `:writer` (`writer_credential_secret_id`, surfaced as `:uploader`/`:writer` role), `:reader` (`reader_credential_secret_id`), and `:retention` (`retention_credential_secret_id`) secrets in `platform.network_credential_secrets` exist, are active, and have no failing `CloudArchiveCredentials` destination/grant status.
   - Verifies the newest `StorageUsageDailyReport` (`computed_at`) on hosted or archive-enabled deployments is no older than `max_report_age_hours` (default `36` hours); emits `down` on missing/failing archive credentials and `degraded`/`down` when usage reporting is stale `> 36h`.
4. **`camera.continuous_recording_silence`**:
   - Queries enabled `CameraRecordingPolicy` rows where `mode == :continuous` (skipping deployments where `RecordingControlState` is explicitly operator-suspended).
   - Counts non-quarantined sealed `RecordingCatalogEntry` blocks (`sealed_at >= now - silence_window_minutes`, default `15` minutes) per `(camera_source_id, stream_profile_id)`.
   - Reports `silent_policy_count` and opaque/bounded policy summaries; transitions to `down` when any active continuous policy seals `0` blocks across the window.

### Decision 6: Alert Emission and Non-Breaking Legacy Coexistence

- **JetStream-first OCSF transitions**: When a `DeclarativeCheckInstance` transitions status or verdict and `alert_policy.emit_ocsf_transition` is true, `DeclarativeChecks.VerdictEventWriter` publishes an OCSF `health.state_change` event via `ServiceRadar.Events.OcsfEventPublisher` to NATS JetStream (`family: :declarative_check`). `EventWriter` persists the event to the active telemetry store (StarRocks when enabled, CNPG when disabled) and evaluates `StatefulAlertRule` incident promotion (`open_on_statuses`, `cooldown_seconds`, `renotify_seconds`). Event publish errors are logged and swallowed so state persistence never rolls back on transient NATS errors (matching `CompositeChecks.VerdictEventWriter` and `health-events` durable retention).
- **Coexistence and 1-Click Legacy Import**:
  - `ServiceCheck` and `CompositeCheck` remain untouched.
  - `DeclarativeChecks.LegacyImporter` provides pure functions `from_service_check/1` (`:http` -> `http_request` + `threshold_assert` + `alert_output`; `:tcp` -> `tcp_connect` + `threshold_assert` + `alert_output`; `:dns` -> `dns_lookup` + `threshold_assert` + `alert_output`) and `from_composite_check/1` (`CompositeCheck` + `CompositeCheckInput` + `CompositeCheckRule` -> `srql_devices` `target_binding` + `decision_table` + `alert_output`). Imported checks are created in `state: "draft"` so operators can run **Test Run**, verify parity, enable the declarative check, and disable the legacy check without duplicate alerts.

## Risks / Trade-offs

- **Blueprint v6 CSS leakage onto Tailwind v4 / daisyUI** -> Mitigated by scoping Blueprint CSS strictly under `.sr-bp6-scope` at build time, syncing `.bp6-dark` locally, and mounting a scoped `portalContainer` inside `.sr-bp6-scope` verified by Vitest/Playwright DOM style assertions.
- **Regex or JSONPath denial-of-service in `extract_field`** -> Mitigated by restricting regexes to linear-time RE2/Rust-regex syntax (`max_pattern_length: 512`, `max_subject_bytes: 65_536`, zero backreferences/lookaround) and restricting JSONPath to a deterministic non-recursive selector subset (`max_depth: 16`, zero script filter expressions).
- **Large `srql_devices` fan-out overloading `serviceradar-agent` or Core** -> Mitigated by 1,000-device paged Core evaluation, bounded target batch sizes in `DeclarativeCheckAssignmentCompiler`, agent admission-control resource budgets (`wasm-plugin-system`), and minimum `interval_seconds >= 30`.
- **Secret leakage through Test Run or `node_snapshots`** -> Mitigated by resolving secrets exclusively inside `SecretBroker` / agent host capability injection and scrubbing secret values from `node_snapshots`, logs, and Test Run traces (`"[REDACTED]"`).

## Migration Plan

1. Land CNPG migrations via `mix ash.codegen` for `platform.declarative_checks`, `platform.declarative_check_credential_bindings`, `platform.declarative_check_instances`, and `platform.declarative_check_edge_observations`.
2. Ship Core DAG schema validator, canonical formatter, pure evaluator, posture evaluators (`#6760`), Oban workers, and Built-in Pack #1 seeder.
3. Ship `declarative-check-runner` WASM plugin (`UploadSignature` signed) and `DeclarativeCheckAssignmentCompiler` for Edge and Hybrid graphs.
4. Ship `/api/v2/declarative-checks` export/import endpoints, SRQL translator/AshAdapter fields, and `web-ng` LiveView + React 19 Blueprint v6 / `@xyflow/react` / `elkjs` / `Monaco` visual builder.
5. Expose "Clone as Declarative Check" in legacy `ServiceCheck` and `CompositeCheck` UIs; keep legacy engines active with zero breaking changes.

## Open Questions

- None; all core architectural decisions (`schema_version: 1` JSONB DAG, `credential_slots` + `SecretBroker`, Blueprint v6 + `@xyflow/react` + `elkjs` + `Monaco`, singleton + fan-out `target_binding`, Core + `declarative-check-runner` WASM runners, and PR `#6760` Pack #1 evaluators) are settled with the Product Owner.
