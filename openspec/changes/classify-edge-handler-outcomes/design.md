## Context

On the durable edge-record lane (`TELEMETRY_EDGE_RECORD_V1_BULK` -> `ServiceRadar.EventWriter.Processors.EdgeRecord`), `ServiceRadar.Edge.Projector` currently exposes one pre-transaction classification seam (`publish/3 -> :ok | {:refused, reason} | {:error, reason}`) and one in-transaction seam (`project/4 -> :ok | {:defer, :pending | :blocked} | {:error, reason}`). `EdgeRecord` dead-letters `{:refused, reason}` on delivery 1 via `ServiceRadar.EventWriter.EdgeRecordRefusedError` (`EdgeRecordDeadLetter.terminal?/1 == true`) and raises `RuntimeError` on `{:error, reason}` (`publish_fresh/6` at `edge_record.ex:332-345`), causing JetStream to redeliver up to `dead_letter_after_deliveries` (`20` in `ServiceRadar.EventWriter.Config`).

Behind `ServiceRadar.Edge.Projectors.WasmPluginResult`, however, two layers destroy outcome structure:

1. `ServiceRadar.Observability.PluginResultIngestor` (`plugin_result_ingestor.ex:141-185, 647-700`) runs up to 11 registered handlers in `platform_contract_handlers/0`. Every non-`:ok` handler return is formatted into sanitized display text `{handler_module, error_text}` and collapsed into `{:error, {:plugin_result_handlers_failed, errors}}` (or `:plugin_result_artifact_cleanup_failed`).
2. `WasmPluginResult.ingest_results/5` (`wasm_plugin_result.ex:107-117`) maps every `{:error, reason}` from `PluginResultIngestor.ingest/2` to `{:error, {:plugin_result_ingest_failed, reason}}`, never `{:refused, _}` and never `{:settled, _}`. `EdgeRecord.publish_fresh/6` raises `"edge record publish failed: ..."`, so every deterministic refusal or withdrawn/superseded observation retries 20 times and lands in `TELEMETRY_EDGE_RECORD_DLQ_V1_BULK` with `Sr-Edge-Dlq-Reason: "RuntimeError"`.

Three recent incidents came from this structural gap:
- Superseded AWX inventory observations (`:stale_awx_membership_generation`, burning 20 deliveries per batch), patched locally in `#6505` via `AwxInventoryObservationFence` + `DeviceDiscoveryIngestor.settle_superseded/2`.
- Proxmox inventory results arriving just after an operator disabled or retracted an assignment (`:plugin_assignment_disabled`), patched locally in `#6519` via `ProxmoxSourceScopeResolver.assignment_withdrawn?/1` inside `PluginResultIngestor.ingest_proxmox/5`.
- An earlier stale AWX membership generation before `#6505`.

Separately, the legacy retained plugin status path (`ServiceRadar.Ingestion.ResultIngestor.conclude_retained_plugin/3`, `ingestion/result_ingestor.ex:38-53`) acknowledges `{:error, {:plugin_result_handlers_failed, _errors}}` immediately once `PluginResultIngestor` commits a `"failed"` marker row. Extending or copying that blanket acknowledgement onto the durable edge-record path would silently drop transient CNPG timeouts, deadlocks, datasvc object-store outages, and AGE graph failures after a single attempt.

## Goals / Non-Goals

- Goals:
  - Define one explicit four-way outcome contract (`applied`, `settled`, `refused`, `retryable`) for every plugin result handler and map it in one place onto `ServiceRadar.Edge.Projector` and `ServiceRadar.EventWriter.Processors.EdgeRecord`.
  - Ensure valid-but-superseded/withdrawn records (`settled`) commit on delivery 1 with preserved `service_status` rows marked `"settled"` (never `"failed"` / `available: false`), one structured log event, and one bounded counter increment.
  - Ensure deterministic contract, ownership, capability, or schema violations (`refused`) dead-letter on delivery 1 (`attempts=1`) into `TELEMETRY_EDGE_RECORD_DLQ_V1_BULK` under their specific bounded `reason` atom (`Sr-Edge-Dlq-Reason`), never `"RuntimeError"`, with full record bytes and out-of-line staged artifacts preserved for inspection and replay.
  - Ensure transient infrastructure failures (`retryable`) NAK for backoff redelivery up to `dead_letter_after_deliveries`, including unclassified `{:error, term}` returns, while emitting an unclassified-error signal so unmigrated error shapes are caught in tests and production.
  - Audit all 18 catalogued edge projectors (`ServiceRadar.Edge.ContractCatalog`) and all 11 registered plugin handlers (`PluginResultIngestor.platform_contract_handlers/0`), leaving zero ambiguous return shapes unaddressed.
- Non-Goals:
  - Extending or refactoring the legacy retained status path (`ServiceRadar.Ingestion.ResultIngestor`).
  - Changing JetStream stream retention policies, `DiscardNew` work-queue semantics, or DLQ partitioning (`add-edge-record-stream-partitioning`).
  - Silently truncating or dropping oversized payloads or failed records.

## Decisions

### Decision 1: Single four-way handler outcome contract and single `Projector` / `EdgeRecord` mapping

Define `ServiceRadar.Observability.PluginResultHandlerOutcome` and `@behaviour ServiceRadar.Observability.PluginResultHandler`:

```elixir
@type reason_atom :: atom()
@type metadata :: map()

@type t ::
        :ok
        | {:settled, reason_atom()}
        | {:settled, reason_atom(), metadata()}
        | {:refused, reason_atom()}
        | {:refused, reason_atom(), metadata()}
        | {:error, term()}

@callback supports?(payload :: map(), status :: map()) :: boolean()
@callback ingest(payload :: map(), status :: map(), opts :: keyword()) :: t()
@callback settled_reasons() :: [reason_atom()]
@callback refused_reasons() :: [reason_atom()]
```

Exact meanings across all handlers and projectors:
- `applied` (`:ok`): Downstream domain state writes succeeded (or converged idempotently to the current desired state). Commit delivery slot and event ledger, persist `"succeeded"` handler marker, ACK on delivery 1.
- `settled` (`{:settled, reason_atom, metadata}`): The record was authentically produced and structurally valid when emitted, and current persisted control-plane state proves its authority was subsequently withdrawn or its ordering generation was superseded (for example `:stale_awx_membership_generation`, `:plugin_assignment_disabled`, `:credential_rule_disabled`, `:device_out_of_service`). Downstream domain tables are deliberately untouched; the reported `service_status` row is preserved, the handler marker is recorded as `"settled"` without forcing `service_state.available = false`, the delivery slot and `event_ledger` row commit on delivery 1, one structured log line and one bounded counter increment are emitted, and the message is ACKed on delivery 1.
- `refused` (`{:refused, reason_atom, metadata}`): Deterministic contract, identity, ownership, capability, bounds, or schema violation that cannot succeed on redelivery of the same record bytes (for example `:plugin_assignment_agent_mismatch`, `:plugin_assignment_not_found`, `:running_config_artifact_hash_mismatch`, `:invalid_advisory`). In `PluginResultIngestor`, the reported `service_status` and `"failed"` handler marker are recorded for operator visibility, and `WasmPluginResult.publish/3` returns `{:refused, {reason_atom, detail_map}}` to `EdgeRecord`. `EdgeRecord` wraps it in `%EdgeRecordRefusedError{reason: {reason_atom, detail_map}}`, which `EdgeRecordDeadLetter` routes to `TELEMETRY_EDGE_RECORD_DLQ_V1_BULK` on delivery 1 (`attempts=1`) with `Sr-Edge-Dlq-Reason: Atom.to_string(reason_atom)` (via `EventWriterTelemetry.failure_class/1`'s `{reason_atom, _}` clause) and `PipelineStats.record(:projector_refused, contract)`. Neither `edge_delivery_slots` nor `event_ledger` is committed, so `EdgeRecordDeadLetter.Replay` can re-project the record after a code or configuration fix without ledger Replay deduplication skipping it.
- `retryable` (`{:error, reason}`): Transient failure (CNPG timeout/deadlock/pool exhaustion, datasvc object-store fetch timeout, JetStream publish timeout, AGE graph error, advisory lock contention) or any unclassified `{:error, term}`. `EdgeRecord` rolls back / skips ledger commit and fails the message so JetStream redelivers with backoff up to `dead_letter_after_deliveries`.

Projector alignment (`ServiceRadar.Edge.Projector` and `ServiceRadar.EventWriter.Processors.EdgeRecord`):
- Extend `Projector.publish/3` return type to `:ok | {:settled, reason_atom() | {reason_atom(), map()}} | {:refused, reason_atom() | {reason_atom(), map()}} | {:error, term()}` and `Projector.project/4` return type to `:ok | {:settled, reason_atom() | {reason_atom(), map()}} | {:defer, :pending | :blocked} | {:refused, reason_atom() | {reason_atom(), map()}} | {:error, term()}`.
- In `EdgeRecord`, `{:settled, settled_reason}` from `publish/3` or `project/4` commits `edge_delivery_slots` and `event_ledger` just like `:ok`, passes `projection: :settled` in `committed/3` context, records `PipelineStats.record(:settled, contract)`, and ACKs the message on delivery 1 (`{:ok, 1}`).
- Enforce the 2-tuple refusal invariant `{reason_atom, detail}` (or bare `reason_atom`) at `EdgeRecordRefusedError` construction so `EventWriterTelemetry.failure_class/1` never receives a 3-tuple (which would fall through to `"error"`) or a nested `{:refused, {:refused, reason}}` (which `ScheduledMtrTrace` currently emits, producing `Sr-Edge-Dlq-Reason: "refused"` instead of `"gateway_unknown"`).

What the durable path takes from -- and rejects in -- legacy `Ingestion.ResultIngestor`:
- Legacy `ResultIngestor.conclude_retained_plugin/3` (`ingestion/result_ingestor.ex:38-53`) ran on the non-durable retained status lane, which had no per-record DLQ stream (`TELEMETRY_EDGE_RECORD_DLQ_V1_BULK`), only an in-memory attempt tracker (`PluginResultQuarantine`). Once `PluginResultIngestor` committed a `"failed"` marker row in `service_status`, `conclude_retained_plugin/3` treated *every* `{:error, {:plugin_result_handlers_failed, _}}` -- including CNPG statement timeouts during `DeviceDiscoveryIngestor` or `WifiMap.BatchIngestor` -- as terminal `:ok` and dropped the message.
- The durable path **keeps** `PluginResultIngestor`'s durable status-marker visibility (`service_status` + `service_state.details["downstream_ingest"]`), extending marker status values from `"succeeded" | "failed"` to `"succeeded" | "settled" | "failed"` so operators and rollout health gates see why a plugin run produced no domain mutations.
- The durable path **rejects** acknowledging `retryable` or `refused` handler failures as `:ok`: `retryable` failures MUST retry on JetStream (without re-inserting duplicate reported `service_status` rows, because `insert_status/2` already detects `:existing` and enters `redeliver/5`), and `refused` failures MUST land in `TELEMETRY_EDGE_RECORD_DLQ_V1_BULK` on delivery 1 so the signed `EdgeRecordV1` frame is never lost. Legacy `ingestion/result_ingestor.ex` is left untouched.

### Decision 2: Multi-handler atomicity, precedence lattice, and `#6505` AWX mixed-batch rule

A single `serviceradar.plugin_result.v1` item can match more than one handler in `PluginResultIngestor.platform_contract_handlers/0` (for example `RunOverrideAckIngestor` alongside `DeviceDiscoveryIngestor`, or `ProxmoxEnrichmentIngestor` alongside `HypervisorEnrichmentIngestor`, or `Camera.InventoryIngestor` alongside `Camera.EventIngestor`).

When `K >= 1` handlers return `supports?(payload, status) == true`:
1. Every matching handler runs against the payload and returns a `PluginResultHandlerOutcome.t()`, normalized through `PluginResultHandlerOutcome.classify(handler, raw_result)` (which validates declared reason membership and turns any undeclared `{:error, reason}` into `retryable` + unclassified-error telemetry).
2. Each handler's individual outcome (`"succeeded"`, `"settled"`, or `"failed"` with bounded reason atom and sanitized message) is recorded in the marker payload (`details["downstream_ingest"]["handlers"]`).
3. Overall item and batch disposition follows the strict precedence lattice:

   `retryable > refused > applied > settled`

   - Any `retryable` handler -> overall `{:error, retryable_summary}`: message NAKed for backoff redelivery; `edge_delivery_slots` and `event_ledger` are not committed; `"failed"` marker persisted so redelivery re-runs handlers (`committed_by?/3` only short-circuits `"succeeded"` or `"settled"` for the current `handler_set` digest). Note: handlers that already committed idempotent writes on attempt 1 must remain idempotent on redelivery (which existing handlers already require under `redeliver/5`).
   - Zero `retryable` and at least one `refused` -> overall `{:refused, {primary_reason_atom, detail_map}}`: `"failed"` marker persisted; dead-lettered on delivery 1 (`attempts=1`) under `primary_reason_atom` (first refused handler in `platform_contract_handlers/0` registration order, with all refused `{handler, reason}` pairs in `detail_map`).
   - Zero `retryable`, zero `refused`, and at least one `applied` (including zero matching handlers, where the status-only plugin result itself is the applied observation) -> overall `:ok` (`applied`): `"succeeded"` marker persisted (noting any co-occurring `"settled"` handlers in `details["downstream_ingest"]`); ledger committed; ACKed on delivery 1.
   - Zero `retryable`, zero `refused`, zero `applied`, and `>= 1` `settled` -> overall `{:settled, {primary_reason_atom, detail_map}}`: `"settled"` marker persisted; `service_state` preserves plugin availability instead of forcing `available: false`; ledger committed; ACKed on delivery 1.

Consistency with `#6505`'s AWX mixed-observation rule:
- Inside `DeviceDiscoveryIngestor`, a single payload can carry AWX controller membership envelopes (`awx_membership` / `device_discovery` with AWX metadata) AND generic non-AWX `device_discovery` entries, or multiple AWX controller aggregates where one controller's generation is superseded and another's is current or un-fenced.
- `#6505` (`AwxInventoryObservationFence.admission/1` + `DeviceDiscoveryIngestor.ingest_payload/3`) established the hard rule that `DeviceDiscoveryIngestor` may settle an observation as `:stale_awx_membership_generation` **only** when every discovery item in the payload is covered by `AwxInventoryObservationFence` and every controller aggregate in the fence is superseded. If a superseded AWX aggregate is mixed with un-ruled generic `device_discovery` items, `DeviceDiscoveryIngestor` MUST NOT settle the payload unapplied -- it returns `{:refused, :mixed_superseded_awx_observation, metadata}` so the mixed batch is dead-lettered on delivery 1 for inspection rather than silently dropping the un-ruled discovery items or retrying 20 times.

### Decision 3: `:plugin_assignment_not_found` is `refused`, not `settled`

In `#6519`, `ProxmoxSourceScopeResolver.assignment_withdrawn?/1` grouped `:plugin_assignment_not_found` alongside `:plugin_assignment_disabled`, `:plugin_assignment_package_not_approved`, `:credential_rule_disabled`, and `:credential_rule_not_found` (logging `:plugin_assignment_not_found` at `:warning` instead of `:info`) solely because the durable path had no first-delivery `refused` outcome from `PluginResultIngestor` and returning `{:error, :plugin_assignment_not_found}` burned 20 deliveries.

Under the four-way outcome contract, `:plugin_assignment_not_found` MUST be `refused`, while `:plugin_assignment_disabled`, `:plugin_assignment_package_not_approved`, `:credential_rule_disabled`, and `:credential_rule_not_found` are `settled`:

1. **Policy-owned `PluginAssignment` rows are retracted in place, never deleted on rule lifecycle changes.** When an operator disables, narrows, or destroys a `NetworkCredentialRule`, `ServiceRadar.Plugins.OwnedAssignmentRetraction` (`owned_assignment_retraction.ex`) transitions the `PluginAssignment` via the `:retract` action (`enabled: false, disabled_reason: :owner_deleted`), and `RejectPolicyOwnedAssignmentDestroy` (`reject_policy_owned_assignment_destroy.ex`) explicitly blocks destroying policy-owned `PluginAssignment` rows (`platform.plugin_assignments` has zero production callers that hard-delete policy-owned Proxmox assignments). By contrast, `NetworkCredentialRule` itself *can* be destroyed, which leaves the `PluginAssignment` row intact (proving `:policy` source, `agent_uid`, `partition_id`, and `plugin_id`) while `CredentialRule.get_by_id/2` returns `{:ok, nil}` (`:credential_rule_not_found`).
2. **Ownership invariants cannot be verified when `PluginAssignment` is missing.** In `ProxmoxSourceScopeResolver.validate_assignment/5` (`proxmox_source_scope_resolver.ex:189-218`), the loaded `PluginAssignment` row is what proves `assignment.source == :policy`, `assignment.agent_uid == authenticated_agent_id`, `assignment.partition_id == authenticated_partition_id`, and `assignment_plugin_id == "proxmox-inventory"` *before* checking `assignment.enabled != true`. When `PluginAssignment` does not exist (`:plugin_assignment_not_found`), core cannot verify that the reporting agent ever owned that assignment UUID in that partition. Settling and ACKing an unverified assignment UUID would treat forged, corrupted, or cross-environment provenance identically to an authorized assignment withdrawal.
3. **Zero retry cost.** Routing `:plugin_assignment_not_found` to `refused` dead-letters it on delivery 1 (`attempts=1`) into `TELEMETRY_EDGE_RECORD_DLQ_V1_BULK` with `Sr-Edge-Dlq-Reason: "plugin_assignment_not_found"`, eliminating the 20-delivery retry storm while preserving the unverified record in DLQ for audit.

### Decision 4: Staged artifact retention across `retryable` and `refused` deliveries, plus `WasmPluginResult` lookup hardening

Auditing `PluginResultIngestor` and `WasmPluginResult` surfaced three concrete defects that would break `retryable` / `refused` guarantees if left in place:

1. **Premature deletion of staged running-config objects (`ServiceRadar.NetworkConfig.PluginIngestor.discard_artifacts/3`)**:
   - Today `PluginResultIngestor.ingest/2` (`lines 99, 106, 111`) calls `PluginIngestor.discard_artifacts(payload, status)` whenever status persistence, service-name remapping, or an unhandled exception fails, and `PluginIngestor.ingest/3` (`network_config/plugin_ingestor.ex:59-62`) calls `discard_artifacts/3` on *every* `{:error, _}` from `do_ingest/3` -- including transient CNPG write failures, datasvc fetch timeouts, and ownership refusals.
   - Deleting the out-of-line staged object on a failed or refused attempt violates `EdgeRecordDeadLetter`'s object-reference invariant (`edge_record_dead_letter.ex:62-71`): if a record hits a transient DB timeout on delivery 1, delivery 2 fails permanently because its staged running-config blob was deleted on delivery 1; if a record is dead-lettered (`refused` or exhausted `retryable`), `EdgeRecordDeadLetter.Replay` can never replay it because the blob is gone.
   - **Fix**: Never call `discard_artifacts/3` on `retryable` or `refused` outcomes on the durable edge-record path. Move staged-artifact cleanup for durable `serviceradar.plugin_results.batch` records into `WasmPluginResult.committed/3` (using `#6383`'s after-commit callback), which runs only after `edge_delivery_slots` and `event_ledger` commit for `applied` or `settled` primary deliveries. Best-effort cleanup failures in `committed/3` log and emit bounded telemetry without failing the committed projection; datasvc object-store bucket TTL handles residual orphans after the DLQ retention window.
2. **Swallowed CNPG errors in `WasmPluginResult.delivery_capabilities/1` (`wasm_plugin_result.ex:148-153`)**:
   - Today `Agent.get_by_uid(agent_id, ...)` maps *every* non-`{:ok, %Agent{}}` return -- including transient CNPG connection timeouts -- to `[]`. If CNPG hiccups during `delivery_capabilities/1`, `ProxmoxSourceScopeResolver` sees `delivery_capabilities: []` and returns `{:missing_proxmox_identity_delivery_capabilities, ...}`. Once `:missing_proxmox_identity_delivery_capabilities` is classified as `refused`, a transient CNPG hiccup would permanently dead-letter valid Proxmox batches on delivery 1!
   - **Fix**: Split `delivery_capabilities/1` into `{:ok, capabilities}` (`%Agent{}` or `NotFound` -> `[]`) vs `{:error, {:plugin_result_agent_lookup_failed, reason}}` (transient DB error -> `retryable`).
3. **Collapsed partition lookup errors in `WasmPluginResult.partition/1`, `FlowAttribution`, and `OtlpRelay`**:
   - `WasmPluginResult.partition/1` (`wasm_plugin_result.ex:173-181`) maps both invalid UUID / `Partition` `NotFound` and transient DB timeouts to `{:error, :plugin_result_batch_partition}` (`retryable`), whereas `WorkloadIdentity` (`workload_identity.ex:188-195`) and `K8sPublicEndpoints` (`k8s_public_endpoints.ex:148-161`) properly split `NotFound` -> `{:refused, :*_partition_not_found}` vs DB error -> `{:error, reason}`. Similarly, `FlowAttribution` (`flow_attribution.ex:115-116, 141`) and `OtlpRelay` (`otlp_relay.ex:136-137, 162`) treat `Partition` `nil` as `{:refused, :*_partition_not_found}` (correct) while keeping DB errors as `{:error, reason}` (`retryable`). `WasmPluginResult.partition/1` will adopt the same `NotFound` -> `{:refused, :plugin_result_batch_partition_not_found}` vs DB error -> `{:error, {:plugin_result_partition_lookup_failed, reason}}` split.

### Decision 5: Bounded observability and anti-regression guardrails

1. **One bounded handler outcome metric family**:
   - Emit `[:serviceradar, :plugin_result, :handler, :outcome]` (`%{count: 1}`, metadata `%{outcome: :applied | :settled | :refused | :retryable, handler: short_handler_name, reason: bounded_reason_atom, agent_id: ..., assignment_id: ...}`).
   - Expose in `ServiceRadar.Telemetry` as `Counter("serviceradar.plugin_result.handler.outcome.count", event_name: [:serviceradar, :plugin_result, :handler, :outcome], measurement: :count, tags: [:outcome, :handler, :reason])`.
   - Cardinality is strictly bounded: `4` outcomes x `11` registered handlers x closed `settled_reasons() ++ refused_reasons() ++ [:ok, :retryable_error]` atoms. High-cardinality fields (`agent_id`, `assignment_id`, `source_instance`, `event_id`) stay in raw `:telemetry` metadata and the single structured log line, never in Prometheus tags.
   - Fold `#6505`'s `serviceradar.inventory.awx_observation.superseded.count` (`telemetry.ex:554-558`, which tagged `source_instance`, an unbounded controller UUID) and `#6519`'s `serviceradar.inventory.proxmox_result.assignment_withdrawn.count` (`telemetry.ex:559-563`) into `serviceradar.plugin_result.handler.outcome.count` during Stage 2 migration (verified zero Helm alert rules, Grafana dashboards, or OpenSpec requirements depend on the two ad-hoc metric names).
2. **Unclassified error safety net**:
   - Any handler returning `{:error, reason}` where `reason` is neither an exception/changeset/DB-error struct nor a declared `retryable` wrapper is treated at runtime as `retryable` (never silently dropped or dead-lettered on attempt 1) AND emits `[:serviceradar, :plugin_result, :handler, :unclassified_error]` (`serviceradar.plugin_result.handler.unclassified_error.count`, tags `[:handler, :reason_class]`) plus a structured warning naming `{handler, reason_class}`.
3. **Contract and `nil`-identity test enforcement**:
   - `plugin_result_handler_outcome_contract_test.exs` iterates over `PluginResultIngestor.platform_contract_handlers/0` and fails CI if any registered handler does not implement `ServiceRadar.Observability.PluginResultHandler`, has overlapping or non-atom `settled_reasons/0` / `refused_reasons/0`, or emits `[:serviceradar, :plugin_result, :handler, :unclassified_error]` across its fixture suite.
   - Every `settled` and `refused` reason in the suite is exercised with primary identity fields missing/`nil` (`assignment_id`, `agent_id`, `partition`, `device_uid`, `controller_id`), asserting that `nil` stays `nil` (never stringified to `"nil"`, preventing the `#6519` `fetch_string/2` atom-to-`"nil"` bug class).

## Exhaustive Inventory Tables

### Table A: All 18 Catalogued Edge Contracts and Projectors (`ServiceRadar.Edge.ContractCatalog`)

Note: Before any projector `decode/1` runs, `EdgeRecord.ingest_decoded/5` (`edge_record.ex:237-271`) enforces frame/header/slot invariants: `PublicationIdentity` header decode errors, `:unsupported_slot_kind`, `:audit_not_late_fenced`, `:network_scope_mismatch`, `:agent_mismatch`, and `:unsupported_payload_family` all return `{:error, reason}` from `ingest_decoded/5` -> `EdgeRecordRefusedError` -> first-delivery DLQ (`refused`), except `WireDecode.transient?/1` reasons which raise `EdgeRecordTransientError` (`retryable`). On `telemetry.edge-record-recovery.v1`, refusals and deferrals retain their broker delivery without DLQ routing (`edge_record.ex:31, 170-175`).

| # | Contract (`{id, v}`) | Projector & Mode | Current Return Shapes | Classification & Stage 2 Action |
|---|---|---|---|---|
| 1 | `{"serviceradar.edge.recovery_control", 1}` | `Projectors.RecoveryControl` (`decode/1`, `project/4`) | `decode`: `:contract_dispatch`; `project`: `:ok`, `{:defer, :pending \| :blocked}`, `{:error, reason}` (`EdgeRecovery` validation atoms vs DB write errors). | `decode` / atom validation errors -> `refused` (retained on recovery stream); `{:defer, _}` -> committed `deferred` retry; DB errors -> `retryable`. No change needed. |
| 2 | `{"serviceradar.sweep.observation", 1}` | `Projectors.SweepObservation` (`decode/1`, `project/4`, `committed/3`) | `decode`: `:unsupported_payload_family` / `SweepObservationCorrelation` validation atoms; `project`: `:ok`, `{:error, {:sweep_batch_slot_conflict, existing}}`, `{:error, lease_or_plan_atom}`, DB exceptions/changesets. | Atom/tuple validation & slot/lease conflicts -> `refused` (`write_failure?/1 == false`); DB exceptions/changesets -> `retryable` (`write_failure?/1 == true`). No change needed. |
| 3 | `{"serviceradar.metrics.batch", 1}` | `Edge.MetricsBatchProjection` (`decode/1`, `publish/3`, `committed/3`) | `decode`: `:unsupported_payload_family`, `:metrics_batch_source_authorization`, `:metrics_batch_empty`, `:metrics_batch_row_count`, wire decode; `publish`: `:ok`, `{:refused, :output_grant_not_current \| :metrics_batch_source}`, `{:error, {:metrics_publish_failed, reason}}`, `PublishDeniedError`. | `decode` errors & `:output_grant_not_current` / `:metrics_batch_source` / `PublishDeniedError` -> `refused` (delivery 1 DLQ); JetStream publish timeout or `OutputGrants` DB error -> `retryable`. No change needed. |
| 4 | `{"serviceradar.sweep.unleased_results", 1}` | `Projectors.UnleasedSweepResults` (`decode/1`, `publish/3`, `committed/3`) | `decode`: `:unsupported_payload_family`, `:unleased_sweep_source_authorization`, count/field checks; `publish`: `:ok` (including `{:declined, :no_hosts \| :stale_sweep_execution}`), `{:refused, :output_grant_not_current \| :sweep_partition_not_found}`, `{:error, reason}`. | Migrate `{:declined, :stale_sweep_execution \| :no_hosts}` from silent `:ok` to `{:settled, reason}` so `PipelineStats` counts `:settled` instead of `:projected`; keep `:output_grant_not_current` & `:sweep_partition_not_found` as `refused` and DB/ingest errors as `retryable`. Bump `projection_revision`. |
| 5 | `{"serviceradar.telemetry.batch", 1}` | `Projectors.TelemetryBatch` (`decode/1`, `publish/3`, `committed/3`) | `decode`: `:unsupported_payload_family`, `:telemetry_batch_source_authorization`, `:telemetry_batch_payload_kind`, `:telemetry_batch_discovery_producer`, `:telemetry_batch_partition`, `:telemetry_batch_producer`; `publish`: `:ok`, `{:refused, :output_grant_not_current}`, `{:error, {:telemetry_metrics_publish_failed \| :telemetry_route_failed, reason}}`. | `decode` & `:output_grant_not_current` -> `refused`; NATS/StarRocks/DB route failures -> `retryable`. Split `Partition` `NotFound` in `publish/3` (if any) as `refused` vs DB lookup error as `retryable`. |
| 6 | `{"serviceradar.mtr.scheduled_trace", 1}` | `Projectors.ScheduledMtrTrace` (`decode/1`, `publish/3`, `committed/3`) | `decode`: `:unsupported_payload_family`, `:scheduled_mtr_source_authorization`, `:scheduled_mtr_trace_missing`, count/field checks; `publish`: `:ok`, `{:refused, :output_grant_not_current \| :mtr_partition_not_found}`, `{:refused, {:refused, :gateway_unknown}}` (`L89-90, 323`), `{:error, reason}`. | **Bug fix**: unwrap `{:refused, {:refused, :gateway_unknown}}` to `{:refused, :gateway_unknown}` so `Sr-Edge-Dlq-Reason` is `"gateway_unknown"` instead of `"refused"`. Keep `:output_grant_not_current` & `:mtr_partition_not_found` as `refused`, publish/DB failures as `retryable`. Bump `projection_revision`. |
| 7 | `{"serviceradar.netprobe.flow_attribution", 1}` | `Projectors.FlowAttribution` (`decode/1`, `publish/3`, `committed/3`) | `decode`: `:unsupported_payload_family`, `:flow_attribution_source_authorization`, batch checks; `publish`: `:ok`, `{:refused, :output_grant_not_current \| :flow_attribution_partition_not_found}`, `{:error, reason}`. | Already splits `:flow_attribution_partition_not_found` (`refused`) from transient lookup/JetStream publish errors (`retryable`). No change needed. |
| 8 | `{"serviceradar.otlp.relay", 1}` | `Projectors.OtlpRelay` (`decode/1`, `publish/3`, `committed/3`) | `decode`: `:unsupported_payload_family`, `:otlp_relay_source_authorization`, frame checks; `publish`: `:ok`, `{:refused, :output_grant_not_current \| :otlp_relay_partition_not_found}`, `{:error, {:otlp_relay_publish_failed, reason}}`. | Already splits `:otlp_relay_partition_not_found` (`refused`) from transient lookup/JetStream publish errors (`retryable`). No change needed. |
| 9 | `{"serviceradar.plugin_results.batch", 1}` | `Projectors.WasmPluginResult` (`decode/1`, `publish/3`, `committed/3`) | `decode`: `:unsupported_payload_family`, `:plugin_result_batch_source_authorization`, `:plugin_result_batch_empty`, `:plugin_result_batch_row_count`, `:plugin_result_batch_no_provenance`, `:plugin_result_no_status`, `:plugin_result_no_summary`; `publish`: `:ok`, `{:refused, :output_grant_not_current}`, `{:error, :plugin_result_batch_partition}`, `{:error, {:plugin_result_ingest_failed, reason}}`. | **Primary target**: split `partition/1` `NotFound` (`{:refused, :plugin_result_batch_partition_not_found}`) vs DB error (`retryable`); stop `delivery_capabilities/1` swallowing CNPG errors; propagate `:ok`, `{:settled, ...}`, `{:refused, ...}`, `{:error, ...}` from `PluginResultIngestor`; add `committed/3` to clean staged running-config artifacts after ledger commit. Bump `projection_revision`. |
| 10 | `{"serviceradar.mapper.devices.batch", 1}` | `Projectors.MapperDevices` (`decode/1`, `publish/3`, `committed/3`) | `decode`: `:unsupported_payload_family`, `:mapper_device_batch_source_authorization`, `:mapper_device_no_anchor`, count checks; `publish` (via `DiscoveryCommon.with_current_grant/2`): `:ok`, `{:refused, :output_grant_not_current}`, `{:error, reason}` (`SyncIngestorQueue` / DB). | `decode` & `:output_grant_not_current` -> `refused`; `SyncIngestorQueue` / CNPG errors -> `retryable`; Split `DiscoveryCommon` partition `NotFound` (`refused`) vs DB error (`retryable`) if lookup fails. |
| 11 | `{"serviceradar.mapper.interfaces.batch", 1}` | `Projectors.MapperInterfaces` (`decode/1`, `publish/3`, `committed/3`) | `decode`: `:unsupported_payload_family`, `:mapper_interface_batch_source_authorization`, `:mapper_interface_no_device`, `:mapper_interface_no_anchor`; `publish`: `:ok`, `{:refused, :output_grant_not_current}`, `{:error, {:mapper_interface_ingest_failed, reason}}`. | `decode` & `:output_grant_not_current` -> `refused`; `InterfaceIngestor` CNPG errors -> `retryable`. No change needed unless `InterfaceIngestor` adds validation atoms. |
| 12 | `{"serviceradar.mapper.topology.batch", 1}` | `Projectors.MapperTopology` (`decode/1`, `publish/3`, `committed/3`) | `decode`: `:unsupported_payload_family`, `:mapper_topology_batch_source_authorization`, `:mapper_topology_link_no_local_device`; `publish`: `:ok`, `{:refused, :output_grant_not_current}`, `{:error, {:mapper_topology_ingest_failed, reason}}`. | `decode` & `:output_grant_not_current` -> `refused`; `TopologyIngestor` CNPG/AGE errors -> `retryable`. No change needed. |
| 13 | `{"serviceradar.netprobe.discovery.batch", 1}` | `Projectors.NetprobeDiscovery` (`decode/1`, `publish/3`, `committed/3`) | `decode`: `:unsupported_payload_family`, `:netprobe_discovery_batch_source_authorization`, `:netprobe_record_no_ip`, `:netprobe_record_no_agent`; `publish` (`DiscoveryCommon`): `:ok`, `{:refused, :output_grant_not_current}`, `{:error, reason}`. | `decode` & `:output_grant_not_current` -> `refused`; `SyncIngestorQueue` / DB errors -> `retryable`. No change needed. |
| 14 | `{"serviceradar.sync.page.batch", 1}` | `Projectors.SyncPage` (`decode/1`, `publish/3`, `committed/3`) | `decode`: `:unsupported_payload_family`, `:sync_page_source_authorization`, `:sync_page_no_run_id`, `:sync_device_no_anchor`; `publish` (`DiscoveryCommon`): `:ok`, `{:refused, :output_grant_not_current}`, `{:error, reason}`. | `decode` & `:output_grant_not_current` -> `refused`; `SyncIngestorQueue` / DB errors -> `retryable`. No change needed. |
| 15 | `{"serviceradar.workload_identity.snapshot", 1}` | `Projectors.WorkloadIdentity` (`decode/1`, `publish/3`, `committed/3`) | `decode`: `:unsupported_payload_family`, `:workload_identity_source_authorization`, `:workload_identity_no_container_id`; `publish`: `:ok`, `{:refused, :output_grant_not_current \| :workload_identity_partition_not_found}`, `{:error, {:workload_identity_persist_failed, reason}}`. | Already splits `:workload_identity_partition_not_found` (`refused`) vs CNPG persist errors (`retryable`). Audit `WorkloadIdentity` domain validation atoms in Stage 2 Task 3.5 so deterministic schema errors map to `refused`. |
| 16 | `{"serviceradar.k8s.public_endpoints.snapshot", 1}` | `Projectors.K8sPublicEndpoints` (`decode/1`, `publish/3`, `committed/3`) | `decode`: `:unsupported_payload_family`, `:k8s_public_endpoints_source_authorization`, `:k8s_public_endpoints_endpoint_cluster_mismatch`; `publish`: `:ok`, `{:refused, :output_grant_not_current \| :k8s_public_endpoints_partition_not_found \| :k8s_inventory_cluster_binding_mismatch \| :invalid_k8s_public_endpoints_snapshot}`, `{:error, reason}`. | Model projector: already cleanly separates `refused` vs `retryable`. No change needed. |
| 17 | `{"serviceradar.endpoint_inventory.scan", 1}` | `Projectors.EndpointInventory` (`decode/1`, `publish/3`, `committed/3`) | `decode`: `:unsupported_payload_family`, `:endpoint_inventory_scan_source_authorization`, `:endpoint_inventory_scan_metadata`; `publish`: `:ok`, `{:refused, :output_grant_not_current}`, `{:error, {:endpoint_inventory_ingest_failed, reason}}`. | Audit `EndpointInventoryIngestor` validation atoms (`:invalid_payload`, missing host anchor) in Task 3.5 -> `refused`; CNPG errors -> `retryable`. Bump `projection_revision` if mapping changes. |
| 18 | `{"serviceradar.bumblebee.scan", 1}` | `Projectors.BumblebeeScan` (`decode/1`, `publish/3`, `committed/3`) | `decode`: `:unsupported_payload_family`, `:bumblebee_scan_source_authorization`, count checks; `publish`: `:ok`, `{:refused, :output_grant_not_current}`, `{:error, {:bumblebee_scan_ingest_failed, reason}}`. | Audit `BumblebeeScanIngestor` validation atoms in Task 3.5 -> `refused`; CNPG/JetStream errors -> `retryable`. Bump `projection_revision` if mapping changes. |

### Table B: `PluginResultIngestor` and All 11 Registered Handlers (`platform_contract_handlers/0`)

#### B.0 `ServiceRadar.Observability.PluginResultIngestor` (Coordinator)

| Return / Condition Today | Target Outcome | Reasoning |
|---|---|---|
| `:invalid_payload` (non-map or empty list) | `refused` (`:invalid_plugin_result_payload`) | Deterministic malformed input; retrying identical bytes cannot produce a valid map. |
| `{:plugin_service_identity_resolution_failed, reason}` (`remap_service_name/1`) | `retryable` on DB lookup error; `refused` only if provenance structure is invalid | `PluginServiceIdentity.resolve/2` queries `PluginAssignment` in CNPG; DB failures are transient. |
| `{:plugin_result_status_persistence_failed, _}`, `:reported_status_allocation_exhausted`, `:reported_status_slot_collision`, `:reported_status_slot_missing`, `:status_slot_lock_busy`, `:handler_marker_window_exhausted`, `:handler_marker_collision`, `{:plugin_result_handler_success_persistence_failed, _}`, `{:plugin_result_handler_failure_persistence_failed, _, _}` | `retryable` | CNPG write/lock/slot contention or outage during status/marker persistence; must redeliver with backoff. |
| `{:handler_not_loadable, _}`, `{:invalid_handler, _}`, `{:support_check_failed, _}`, `{:unexpected_support_result, _}` | `retryable` + `unclassified_error` telemetry | Runtime/configuration defect in core, never an agent error; retrying avoids dropping data during fix/rollout while alerting immediately. |
| Rescued exception / exit / throw in `ingest/2` or `ingest_handler/5` | `retryable` | Unexpected runtime crash or DB connection exit; redeliver up to DLQ threshold. |

#### B.1 `ServiceRadar.NetworkConfig.PluginIngestor` (`network_config`)

| Return / Condition Today | Target Outcome | Reasoning |
|---|---|---|
| Normal running-config snapshot ingested (`NetworkConfig.Ingest.ingest_snapshots/2 -> :ok`) | `applied` (`:ok`) | Snapshot + diff persisted; staged object deleted in `WasmPluginResult.committed/3`. |
| `:missing_running_config`, `:running_config_result_incomplete` | `refused` | Deterministic schema violation in reported `network_config` block. |
| `:running_config_artifact_agent_unknown`, `:running_config_artifact_key_invalid`, `:running_config_artifact_key_not_owned`, `:running_config_artifact_assignment_not_owned` | `refused` | Deterministic object-key ownership / path-traversal / provenance violation (`network_config/plugin_ingestor.ex:212-226`). |
| `:running_config_artifact_hash_mismatch`, `:running_config_artifact_not_utf8` | `refused` | Deterministic content-integrity or encoding violation against the declared SHA-256 / UTF-8 contract. |
| `{:running_config_artifact_fetch_failed, reason}` (datasvc gRPC / object-store timeout or unavailable; `:not_found` discussed below) | `retryable` (transient datasvc/network errors); `:artifact_not_found` -> `refused` | Transient datasvc timeouts succeed on retry *once `discard_artifacts/3` is removed from the failure path*. If the object store authoritatively confirms `:not_found` on delivery 1, no blob exists to fetch on retry -> `refused`. |
| `NetworkConfig.Ingest.ingest_snapshots/2` DB/Ash write errors; `:running_config_ingest_failed` | `retryable` | CNPG write failure; staged blob remains intact for retry. |

#### B.2 `ServiceRadar.NetworkConfig.InterfaceCheckIngestor` (`interface_config_check`)

| Return / Condition Today | Target Outcome | Reasoning |
|---|---|---|
| Verdicts recorded; missing device UID skipped (`:not_found` in `lookup_device/2`, `L46`) | `applied` (`:ok`) | Existing contract logs warning for unknown device UID and records remaining verdicts. |
| `:interface_check_invalid_result`, `:interface_check_too_many_verdicts` | `refused` | Deterministic schema or ceiling (`@max_verdicts`) violation in payload. |
| `{:interface_check_record_failed, count}`, `lookup_device/2` / `Ash` CNPG errors | `retryable` | Transient CNPG read/write failure while recording interface check verdicts. |

#### B.3 `ServiceRadar.Plugins.RunOverrideAckIngestor` + `ServiceRadar.Plugins.RunOverrides`

| Return / Condition Today | Target Outcome | Reasoning |
|---|---|---|
| Overrides acknowledged (`RunOverrides.acknowledge/3 -> :ok`, including already-acked/expired IDs) | `applied` (`:ok`) | Idempotent acknowledgement of `PluginRunOverride` rows. |
| `:missing_plugin_assignment` (when `status.plugin_provenance["assignment_id"]` is absent/blank) | `refused` (`:missing_plugin_assignment_provenance`) | Without host-stamped `assignment_id` provenance, core cannot scope override acknowledgement to an assignment; retrying same bytes never adds provenance. |
| `Ash.BulkResult` errors, `:bulk_update_failed`, CNPG query errors | `retryable` | Transient CNPG failure updating `platform.plugin_run_overrides`. (Note: `RunOverrides` creation-only errors like `:missing_override_id`, `{:unknown_operation, _}`, `:descriptor_does_not_allow_overrides`, `:invalid_expires_at`, `:missing_expiry` occur in control-plane creation, not `acknowledge/3`; if ever reached in `acknowledge/3`, invalid UUIDs are ignored or `refused`.) |

#### B.4 `ServiceRadar.Inventory.DeviceDiscoveryIngestor` (+ `AwxInventoryObservationFence`, `AwxMembershipReconciler`, `DeviceSourceObservationIngestor`)

| Return / Condition Today | Target Outcome | Reasoning |
|---|---|---|
| Discovery synced, source snapshot activated (or `:idempotent`), AWX memberships reconciled | `applied` (`:ok`) | Normal or idempotent convergence. |
| `{:superseded, [{:stale_awx_membership_generation, controller_id, observed_gen, high_water}, ...]}` when ALL discovery items in payload are AWX-fenced | `settled` (`:stale_awx_membership_generation`) | Matches `#6505`: newer controller generation already applied; valid out-of-order observation deliberately not applied. |
| Superseded AWX aggregate mixed with un-ruled generic `device_discovery` items (`#6505` fence guard) | `refused` (`:mixed_superseded_awx_observation`) | Un-ruled generic discovery items cannot be silently settled and cannot succeed while the AWX half is stale; dead-letter on delivery 1. |
| `:awx_inventory_observation_conflict` (same `(controller_id, generation)` already recorded with a *different* `source_fingerprint`) | `refused` (`:awx_inventory_observation_conflict`) | Deterministic fencing conflict: producer emitted two different fingerprints for one immutable controller generation. |
| `AwxMembershipReconciler` parse/bounds errors: `{:too_many_awx_aggregates, _, _}`, `{:too_many_hosts, _, _}`, `{:too_many_awx_device_evidence_rows, _}`, `{:invalid_awx_membership_aggregate, _}`, `:invalid_devices`, `{:controller_mismatch, _, _}`, `:missing_awx_host_metadata`, `:invalid_awx_host`, `:host_generation_mismatch`, `:host_fingerprint_mismatch`, `:duplicate_awx_controller_aggregate`, `:duplicate_awx_host_source_tuple`, `:invalid_controller_id`, `:invalid_positive_integer`, `:invalid_source_generation`, `:invalid_source_fingerprint`, `:invalid_boolean`, `:invalid_observed_at`, `:missing_required_string` | `refused` (mapped to canonical `reason_atom` + detail map) | Deterministic schema, digest, or ceiling violations in the AWX payload. |
| `AwxMembershipReconciler` `:awx_inventory_observation_bootstrap_requires_newer_generation`, `:same_observation_authority_changed`, `{:too_many_existing_awx_memberships, _, _}` | See **Open Decision 1** (default recommendation: `:awx_inventory_observation_bootstrap_requires_newer_generation` -> `settled`; `:same_observation_authority_changed` -> `retryable`; `{:too_many_existing_awx_memberships, _, _}` -> `refused`) | Explicitly surfaced in Open Decisions for user confirmation before Stage 2. |
| `DeviceSourceObservationIngestor` schema/bounds errors: `:incomplete_source_snapshot`, `:invalid_inventory_source`, `:invalid_source_instance`, `:invalid_collection_id`, `:invalid_content_hash`, `:invalid_query_hash`, `:invalid_snapshot_timestamp`, `:source_snapshot_device_limit_exceeded`, `:duplicate_source_object`, `:invalid_source_object_id`, `:invalid_source_integration_id`, `:source_metadata_too_large`, `:invalid_resolved_source_snapshot`, `:invalid_resolved_source_observation` | `refused` | Deterministic schema or bounds violations in `source_observation` envelope. |
| `DeviceSourceObservationIngestor` `{:unresolved_source_identifiers, unresolved}` / `:unresolved_source_identifier` | See **Open Decision 2** (default recommendation: `retryable` when companion device sync in the same or concurrent batch has not materialized yet, or `refused` if sync already ran in-band and still produced zero resolvable anchor) | Explicitly surfaced in Open Decisions for user confirmation before Stage 2. |
| `SyncIngestor.ingest_updates/2` CNPG timeouts (`ERROR 57014 query_canceled`), deadlocks, `AwxMembershipReconciler` upsert/expire/notification DB errors, `AwxInventoryObservationFence.lock_controller/1` DB errors, `:source_observation_preflight_failed`, `:source_observation_ingest_failed` | `retryable` | Transient CNPG / lock / notification failures (such as statement timeouts under transient database contention). |

#### B.5 `ServiceRadar.Inventory.ProxmoxSourceScopeResolver` (invoked by `PluginResultIngestor` for Proxmox handlers)

| Return / Condition Today | Target Outcome | Reasoning |
|---|---|---|
| `:plugin_assignment_disabled`, `:plugin_assignment_package_not_approved`, `:credential_rule_disabled`, `:credential_rule_not_found` | `settled` | Matches `#6519`: verified policy-managed assignment whose operator authority was withdrawn while the plugin run was in flight. |
| `:plugin_assignment_not_found` | `refused` | See **Decision 3**: policy-owned `PluginAssignment` rows are retracted in place (`:retract`), never hard-deleted; missing assignment prevents verifying `:policy` source, `agent_uid`, `partition_id`, and `plugin_id`. |
| `:invalid_proxmox_result_envelope`, `:invalid_plugin_assignment`, `:missing_trusted_assignment_id`, `:conflicting_trusted_assignment_ids`, `:missing_authenticated_agent_id`, `:missing_authenticated_partition_id`, `:proxmox_inventory_plugin_mismatch`, `{:missing_proxmox_identity_delivery_capabilities, _}`, `:plugin_assignment_id_mismatch`, `:plugin_assignment_not_policy_managed`, `:plugin_assignment_agent_mismatch`, `:plugin_assignment_partition_mismatch`, `:plugin_assignment_plugin_mismatch`, `:plugin_assignment_package_mismatch`, `:plugin_assignment_policy_mismatch`, `:invalid_proxmox_inventory_policy_id`, `:invalid_proxmox_console_policy_id`, `:unsupported_proxmox_assignment_plugin`, `:credential_rule_id_mismatch`, `:credential_rule_provider_mismatch`, `:credential_rule_purpose_mismatch`, `:proxmox_tls_verification_required`, `:unsupported_proxmox_inventory_auth_method`, `:proxmox_ssh_host_key_verification_required`, `:unsupported_proxmox_console_auth_method`, `:unsupported_proxmox_rule_purpose`, `:invalid_uuid` | `refused` | Deterministic provenance, ownership, capability, transport-security, or UUID violations (note: `WasmPluginResult.delivery_capabilities/1` is hardened in Decision 4 so transient CNPG errors never masquerade as `:missing_proxmox_identity_delivery_capabilities`). |
| `{:plugin_assignment_lookup_failed, reason}`, `{:credential_rule_lookup_failed, reason}`, `:plugin_assignment_package_not_loaded` | `retryable` | Transient CNPG read / preload failure. |

#### B.6 `ServiceRadar.Inventory.HypervisorEnrichmentIngestor` (`hypervisor_enrichment` / `virtualization_inventory`)

| Return / Condition Today | Target Outcome | Reasoning |
|---|---|---|
| Enrichment applied; internal per-item skips (`{:skip, :invalid_saved_owner}`, `{:skip, {:missing_or_inactive_virtualization_endpoint, _}}`) | `applied` (`:ok`) | Internal skips already continue processing the remaining batch (`L460, 469`). |
| `:proxmox_v3_identity_required`, `:missing_authoritative_proxmox_identity`, `:proxmox_source_scope_mismatch`, `:invalid_trusted_proxmox_source_scope`, `:missing_trusted_proxmox_source_scope`, `:invalid_uuid` | `refused` | Deterministic identity/scope contract violation on Proxmox v3 records. |
| `:incomplete_hosted_projection_page`, `:invalid_hosted_projection_cursor` (when malformed payload page/cursor), vs `:incomplete_hosted_inventory_read` / `:incomplete_hosted_owner_ancestry` (pagination read truncation in DB) | Malformed payload cursor/page -> `refused`; DB read pagination/lookup errors (`{:device_lookup_failed, _}`, `{:identifier_lookup_failed, _}`, `Ash.BulkResult` errors, `Repo.rollback`) -> `retryable` | Separates malformed agent pagination envelope (`refused`) from CNPG query/ancestry read states (`retryable`). |

#### B.7 `ServiceRadar.Inventory.ProxmoxEnrichmentIngestor` (`proxmox_inventory`)

| Return / Condition Today | Target Outcome | Reasoning |
|---|---|---|
| Enrichment applied | `applied` (`:ok`) | Normal convergence (after `ProxmoxSourceScopeResolver` succeeds). |
| Raised `ArgumentError` in `mint_scoped_child_ref` (`L728`, missing/invalid child scope identifiers) | Convert `ArgumentError` on malformed payload child ref to `{:refused, :invalid_proxmox_child_ref, metadata}` | Malformed payload field should refuse cleanly rather than raising an unhandled `ArgumentError` for 20 retries. |
| CNPG / `Ash` / `HypervisorEnrichmentIngestor` delegation DB errors | `retryable` | Transient database write/read failure. |

#### B.8 `ServiceRadar.Inventory.VulnerabilityAdvisoryIngestor` (`advisory_feeds`)

| Return / Condition Today | Target Outcome | Reasoning |
|---|---|---|
| Advisories ingested | `applied` (`:ok`) | Normal convergence. |
| `:invalid_payload`, `:invalid_advisories`, `:invalid_advisory`, `:invalid_affected_coordinates`, `:invalid_affected_coordinate`, `{:required, key}` | `refused` (mapped to canonical atoms, e.g. `:missing_required_advisory_field` with `%{field: key}`) | Deterministic schema violation in `advisory_feeds` batch. |
| CNPG transaction / bulk upsert errors | `retryable` | Transient database failure. |

#### B.9 `ServiceRadar.WifiMap.BatchIngestor` (`wifi_survey` / `wifi_map`)

| Return / Condition Today | Target Outcome | Reasoning |
|---|---|---|
| Survey batch upserted (or non-matching schema ignored) | `applied` (`:ok`) | Normal convergence. |
| Deterministic payload validation failures (invalid survey/floorplan coordinates or missing required batch identifiers, if present) | `refused` | Malformed survey payload cannot succeed on retry. |
| CNPG transaction rollback, `{:unexpected_source_upsert_result, _}`, `{:unexpected_batch_upsert_result, _}`, `{:unexpected_bulk_upsert_result, _, _}`, rescued DB exceptions | `retryable` | Transient CNPG failure. |

#### B.10 `ServiceRadar.Observability.ThreatIntelPluginIngestor` (`threat_intel`)

| Return / Condition Today | Target Outcome | Reasoning |
|---|---|---|
| Threat-intel page ingested | `applied` (`:ok`) | Normal convergence. |
| `ThreatIntel.Page` parse/validation errors (invalid schema, invalid indicator shape, missing required page fields) | `refused` | Deterministic payload validation failure. |
| `{:cursor_gap, current_page, start_page}` (`threat_intel_plugin_ingestor.ex:386`) | See **Open Decision 3** (default recommendation: `retryable` when pages 1..N-1 are still in flight across concurrent consumers or retries; or `settled` / `refused` if pages are strictly single-lane ordered and a gap means an earlier run aborted) | Explicitly surfaced in Open Decisions for user confirmation before Stage 2. |
| `Ash.BulkResult` errors, CNPG / JetStream indicator publish errors | `retryable` | Transient persistence/publish failure. |

#### B.11 `ServiceRadar.Camera.EventIngestor` + `ServiceRadar.Camera.InventoryIngestor` (`camera_events` / `camera_descriptors`)

| Handler | Return / Condition Today | Target Outcome | Reasoning |
|---|---|---|---|
| `Camera.EventIngestor` | All events published (`OcsfEventPublisher.publish/2 -> {:ok, _}`) | `applied` (`:ok`) | Normal event publication. |
| `Camera.EventIngestor` | `OcsfEventPublisher.publish/2 -> {:error, :suppressed}` (device is out of service: retired/maintenance) when **all** camera events in payload are suppressed (already returns `:ok` today at `camera/event_ingestor.ex:60-61`) | `settled` (`:device_out_of_service`) when all events are suppressed and `>= 1` event was present; `applied` when at least one event published | Surfaces deliberate out-of-service suppression in the unified `settled` metric and status marker instead of silently looking identical to `applied`. |
| `Camera.EventIngestor` | Malformed camera event schema vs NATS/CNPG publish error in `OcsfEventPublisher.publish/2` | Schema error -> `refused`; NATS/CNPG error -> `retryable` | Deterministic vs transient split. |
| `Camera.InventoryIngestor` | Descriptors synced; per-descriptor `{:skip, "missing required camera identity fields"}` or `{:ip_conflict, _, _}` handled internally | `applied` (`:ok`) (or `refused` `:missing_camera_identity` if *every* descriptor in a non-empty camera inventory payload lacks required identity fields -- see note) | Preserves partial-batch resilience when one camera lacks hints while surfacing completely invalid payloads; CNPG errors (`{:source_lookup_failed, _}`, `{:device_lookup_failed, _}`, Ash errors) -> `retryable`; deterministic `:agent_managed_source_device` / `{:invalid_camera_update_target, _, _}` -> `refused`. |

## Migration Plan

1. **Step 1 -- Core contract, projector mapping, and metrics (`Tasks 1.1 - 1.5`)**:
   - Land `PluginResultHandlerOutcome`, `PluginResultHandler` behaviour, `Projector` + `EdgeRecord` `:settled` and 2-tuple `:refused` support, `PipelineStats` `:settled`, and `ServiceRadar.Telemetry` bounded metrics (`outcome.count` + `unclassified_error.count`). Unmigrated handlers still return `:ok | {:error, _}`, which defaults to `retryable`, so Step 1 is 100% backwards-compatible.
2. **Step 2 -- Migrate `#6505` and `#6519` first (`Tasks 2.1 - 2.2`)**:
   - Convert `AwxInventoryObservationFence` + `DeviceDiscoveryIngestor` and `ProxmoxSourceScopeResolver` + `PluginResultIngestor.ingest_proxmox/5` onto the contract.
   - Verify zero behavioral drift on confirmed settled withdrawals (`:stale_awx_membership_generation`, `:plugin_assignment_disabled`, `:plugin_assignment_package_not_approved`, `:credential_rule_disabled`, `:credential_rule_not_found`), intentional upgrade of `:plugin_assignment_not_found` and `:mixed_superseded_awx_observation` / `:awx_inventory_observation_conflict` to first-delivery `refused`, and fold `awx_observation.superseded` + `proxmox_result.assignment_withdrawn` into `serviceradar.plugin_result.handler.outcome.count`.
3. **Step 3 -- Migrate remaining handlers, staged artifact cleanup, and projector alignments (`Tasks 3.1 - 3.5`)**:
   - Migrate `NetworkConfig.PluginIngestor` (moving `discard_artifacts/3` to `WasmPluginResult.committed/3`), `InterfaceCheckIngestor`, `RunOverrideAckIngestor`, remaining inventory/advisory/wifi/threat-intel/camera handlers, and `ScheduledMtrTrace` / `UnleasedSweepResults` / `WasmPluginResult` lookup splits, bumping `ContractCatalog` `projection_revision` and updating `contract_bundle_golden_test.exs`.
4. **Step 4 -- Enforce contract & integration tests (`Tasks 4.1 - 4.3`)**:
   - Enable strict contract test (`plugin_result_handler_outcome_contract_test.exs`) requiring zero unclassified errors across all 11 handlers, `nil`-identity coverage, multi-handler lattice coverage, and end-to-end JetStream DLQ / replay verification.

## Data Preservation Invariants

- **Never silently drop or truncate**: Every admitted `EdgeRecordV1` either commits in `platform.edge_delivery_slots` + `platform.event_ledger` (`applied` or `settled`) or is preserved byte-for-byte with transport headers in `TELEMETRY_EDGE_RECORD_DLQ_V1_BULK` (`refused` on delivery 1, or exhausted `retryable` at `dead_letter_after_deliveries`).
- **Settled status visibility**: A `settled` plugin result still writes its reported `service_status` row and a `"settled"` handler marker (with bounded `reason` and detail in `details["downstream_ingest"]`), without flipping `service_state.available` to `false` or masquerading as a handler failure.
- **Out-of-line staged artifacts**: Staged running-config blobs in datasvc object store are never deleted on `retryable` or `refused` deliveries; deletion runs only in `WasmPluginResult.committed/3` after the ledger transaction commits.

## Open Decisions (For User Review Before Stage 2 Implementation)

1. **`AwxMembershipReconciler` authority/bootstrap edge cases (`awx_membership_reconciler.ex:229, 241, 337, 382`)**:
   - `:awx_inventory_observation_bootstrap_requires_newer_generation`: occurs when memberships exist in CNPG with no prior fence row and an older/un-bootstrapped generation arrives. **Recommended**: `settled` (same physical cause as `:stale_awx_membership_generation`: the observation lost an ordering race against already-materialized state).
   - `:same_observation_authority_changed`: occurs mid-reconcile when concurrent authority changed between read and upsert/expire. **Recommended**: `retryable` (on redelivery, `AwxInventoryObservationFence` will cleanly classify the next attempt as `settled` if superseded or `applied` if current).
   - `{:too_many_existing_awx_memberships, count, max}`: **Recommended**: `refused` (`:awx_existing_membership_ceiling_exceeded`) so an over-ceiling controller does not spin 20 heavy DB queries per batch, while preserving the batch in DLQ.
2. **`DeviceSourceObservationIngestor` `{:unresolved_source_identifiers, unresolved}` (`device_source_observation_ingestor.ex:368, 378`)**:
   - Occurs when a `source_observation` snapshot names device identifiers that `IdentityReconciler` / CNPG still cannot resolve after in-band `SyncIngestor.ingest_updates/2`.
   - **Option 2A (Recommended)**: `refused` (`:unresolved_source_identifiers`) when the payload carried no pending async sync work (since `DeviceDiscoveryIngestor` runs `SyncIngestor.ingest_updates/2` synchronously first at `device_discovery_ingestor.ex:147-153`, retrying identical bytes without Strong Identifiers will fail identically), OR **Option 2B**: `retryable` if an external discovery source (e.g. mapper/Armis) is expected to materialize the anchor device within the retry window.
3. **`ThreatIntelPluginIngestor` `{:cursor_gap, current_page, start_page}` (`threat_intel_plugin_ingestor.ex:386`)**:
   - Occurs when a multi-page threat-intel feed run delivers page `start_page > current_page + 1` relative to the persisted run cursor.
   - **Option 3A (Recommended)**: `retryable` -- EventWriter processes edge records concurrently up to batch/consumer parallelism or across retries, so page `N+1` can arrive slightly ahead of page `N`; NAKing lets page `N` commit and page `N+1` succeed on redelivery, falling back to DLQ after 20 attempts if page `N` was never produced.
   - **Option 3B**: `refused` (`:threat_intel_cursor_gap`) if threat-intel pages are strictly serialized on a single spool sequence and a gap only occurs when an earlier page was permanently lost/refused.
