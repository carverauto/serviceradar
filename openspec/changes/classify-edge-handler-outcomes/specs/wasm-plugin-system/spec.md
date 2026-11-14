## ADDED Requirements

### Requirement: Plugin result handlers classify outcomes into four explicit dispositions
Every platform handler registered with `ServiceRadar.Observability.PluginResultIngestor` SHALL implement `ServiceRadar.Observability.PluginResultHandler`, declare closed disjoint `settled_reasons/0` and `refused_reasons/0` atom lists, and return an outcome classified into one of four dispositions: `applied` (`:ok`), `settled` (`{:settled, reason}` or `{:settled, reason, metadata}`), `refused` (`{:refused, reason}` or `{:refused, reason, metadata}`), or `retryable` (`{:error, reason}`).

`settled` SHALL be returned only when the plugin result was authentically produced and structurally valid, and persisted control-plane state proves its authority was withdrawn or its ordering generation was superseded before projection. A `settled` outcome SHALL preserve the reported `service_status` row, record a `"settled"` handler marker in `details["downstream_ingest"]` without forcing `service_state.available` to `false`, emit one structured log entry and one bounded counter increment, and acknowledge the durable edge record on its first delivery.

`refused` SHALL be returned for deterministic contract, provenance, ownership, capability, integrity, ceiling, or schema violations that cannot succeed on redelivery of the same record bytes, including `:plugin_assignment_not_found` when a policy-managed assignment row does not exist to prove ownership. A `refused` outcome SHALL persist the `"failed"` handler marker for status visibility and route the enclosing durable edge record to `TELEMETRY_EDGE_RECORD_DLQ_V1_BULK` on its first delivery under its bounded `reason` atom.

`retryable` SHALL be returned for transient database, lock, graph, queue, or object-store failures so JetStream redelivers with backoff up to `dead_letter_after_deliveries`. Any handler `{:error, term}` whose reason is not a declared `settled` or `refused` outcome SHALL default to `retryable` and, when unclassified, SHALL emit `[:serviceradar, :plugin_result, :handler, :unclassified_error]` so unmigrated error shapes never drop or prematurely dead-letter data. Missing optional or failed identity fields in outcome metadata and logs SHALL remain `nil` and SHALL NOT be stringified to `"nil"`.

#### Scenario: Withdrawn Proxmox assignment settles on first delivery
- **GIVEN** a valid Proxmox inventory plugin result batch whose policy-owned `PluginAssignment` row matches the authenticated agent and partition and has `enabled: false` (`:plugin_assignment_disabled`)
- **WHEN** `WasmPluginResult` projects the edge record through `PluginResultIngestor`
- **THEN** the handler SHALL return `{:settled, :plugin_assignment_disabled, metadata}`
- **AND** `PluginResultIngestor` SHALL preserve the reported `service_status` row with a `"settled"` downstream marker without marking the service unavailable
- **AND** `EdgeRecord` SHALL commit the delivery slot and event ledger and acknowledge the message on delivery 1 without dead-lettering it

#### Scenario: Missing Proxmox assignment row is refused on first delivery
- **GIVEN** a Proxmox inventory plugin result batch naming an `assignment_id` that has no `PluginAssignment` row in `platform.plugin_assignments`
- **WHEN** `WasmPluginResult` projects the edge record through `PluginResultIngestor`
- **THEN** the handler SHALL return `{:refused, :plugin_assignment_not_found, metadata}` because ownership invariants cannot be verified
- **AND** `EdgeRecord` SHALL fail the record with `EdgeRecordRefusedError` so `EdgeRecordDeadLetter` copies it to `TELEMETRY_EDGE_RECORD_DLQ_V1_BULK` on delivery 1 with `Sr-Edge-Dlq-Reason` set to `plugin_assignment_not_found`

#### Scenario: Unclassified handler error defaults to retryable and emits diagnostic telemetry
- **GIVEN** a registered plugin result handler that returns an undeclared `{:error, :unexpected_ad_hoc_atom}` tuple
- **WHEN** `PluginResultIngestor` classifies the handler return
- **THEN** it SHALL emit `[:serviceradar, :plugin_result, :handler, :unclassified_error]`
- **AND** it SHALL classify the outcome as `retryable` so the durable edge record is redelivered rather than acknowledged or dead-lettered on delivery 1

#### Scenario: Missing provenance or target identity stays nil
- **GIVEN** a plugin result whose `settled` or `refused` path runs when an optional or unparsed identity field is absent
- **WHEN** the handler and coordinator build outcome metadata and structured log fields
- **THEN** the absent identity field SHALL remain `nil`
- **AND** no log field, marker attribute, or metric tag SHALL coerce `nil` into the string `"nil"`

### Requirement: Multi-handler plugin results resolve under a deterministic precedence lattice
When a `serviceradar.plugin_result.v1` item matches multiple registered handlers in `ServiceRadar.Observability.PluginResultIngestor`, the coordinator SHALL evaluate all matching handlers, record each handler's individual status (`"succeeded"`, `"settled"`, or `"failed"`) in `details["downstream_ingest"]`, and combine their dispositions using the precedence order `retryable > refused > applied > settled`.

Within `ServiceRadar.Inventory.DeviceDiscoveryIngestor`, a payload mixing superseded AWX inventory observations with un-ruled generic `device_discovery` items SHALL NOT settle as `:stale_awx_membership_generation`; it SHALL return `{:refused, :mixed_superseded_awx_observation, metadata}` so un-ruled discovery items are never acknowledged unapplied.

#### Scenario: Applied and settled handlers on the same result commit as applied
- **GIVEN** a plugin result that matches two handlers where one returns `:ok` (`applied`) and the other returns `{:settled, :device_out_of_service, metadata}`
- **WHEN** `PluginResultIngestor` combines their outcomes
- **THEN** the per-handler markers SHALL record `"succeeded"` for the first handler and `"settled"` for the second
- **AND** the combined result SHALL be `:ok` (`applied`), committing the ledger and acknowledging on delivery 1

#### Scenario: Retryable outranks refused and settled in a multi-handler result
- **GIVEN** a plugin result that matches two handlers where one returns `{:refused, reason, metadata}` (or `{:settled, reason, metadata}`) and the other returns a `retryable` `{:error, timeout}`
- **WHEN** `PluginResultIngestor` combines their outcomes
- **THEN** the combined result SHALL be `retryable` so the message is redelivered with backoff and neither acknowledged unapplied nor dead-lettered prematurely

#### Scenario: Mixed superseded AWX and un-ruled discovery payload is refused
- **GIVEN** a plugin result carrying both a superseded AWX controller membership observation and generic non-AWX `device_discovery` entries
- **WHEN** `DeviceDiscoveryIngestor` evaluates the payload
- **THEN** it SHALL return `{:refused, :mixed_superseded_awx_observation, metadata}` rather than settling the batch

### Requirement: Plugin handler outcomes emit one bounded telemetry family and preserve staged artifacts until commit
The control plane SHALL record every evaluated plugin handler outcome under the bounded metric `serviceradar.plugin_result.handler.outcome.count` (`[:serviceradar, :plugin_result, :handler, :outcome]`) tagged only by `[:outcome, :handler, :reason]`, folding superseded AWX observations and withdrawn Proxmox assignments into that single metric family rather than maintaining per-handler counters or unbounded instance tags.

Out-of-line staged artifacts referenced by a `serviceradar.plugin_results.batch` record (such as staged running-config objects read by `ServiceRadar.NetworkConfig.PluginIngestor`) SHALL NOT be deleted when an ingest attempt returns `retryable` or `refused`. On the durable edge-record path, staged artifacts SHALL be deleted only in `WasmPluginResult.committed/3` after the delivery slot and event ledger transaction commits for an `applied` or `settled` primary delivery.

#### Scenario: Staged running-config artifact survives transient failure and DLQ replay
- **GIVEN** a `serviceradar.plugin_results.batch` record referencing a staged running-config object in the object store
- **WHEN** delivery 1 fails with a `retryable` database timeout or is dead-lettered with a `refused` outcome
- **THEN** `PluginIngestor` SHALL NOT delete the staged object during the failed or refused attempt
- **AND** a subsequent retry or `EdgeRecordDeadLetter.Replay` run SHALL still be able to fetch the staged object, deleting it only after `WasmPluginResult.committed/3` runs following ledger commit

#### Scenario: Handler outcome metric tags remain bounded
- **GIVEN** `AwxInventoryObservationFence` settling observations across many distinct AWX `controller_id` UUIDs and `ProxmoxSourceScopeResolver` settling results across many `assignment_id` UUIDs
- **WHEN** handler outcome telemetry is emitted to Prometheus
- **THEN** `serviceradar.plugin_result.handler.outcome.count` SHALL carry only bounded `:outcome`, `:handler`, and `:reason` tags
- **AND** `controller_id` and `assignment_id` SHALL appear only in untagged `:telemetry` metadata and single-shot structured logs
