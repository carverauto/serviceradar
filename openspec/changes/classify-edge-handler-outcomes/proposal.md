# Change: Classify plugin result handler and edge projector outcomes in one place

## Why

Three times in two days a record that can never succeed on redelivery reached a running deployment, was treated as a retryable failure, and burned 20 JetStream deliveries (`dead_letter_after_deliveries: 20` in `ServiceRadar.EventWriter.Config`) before landing in `TELEMETRY_EDGE_RECORD_DLQ_V1_BULK`: superseded AWX inventory observations (`#6505`), withdrawn Proxmox inventory assignments (`#6519`), and an earlier stale AWX membership generation. Today `ServiceRadar.Observability.PluginResultIngestor` collapses every handler `{:error, reason}` into sanitized text inside `{:error, {:plugin_result_handlers_failed, errors}}`, `ServiceRadar.Edge.Projectors.WasmPluginResult.publish/3` wraps every ingest failure as `{:error, {:plugin_result_ingest_failed, reason}}`, and `ServiceRadar.EventWriter.Processors.EdgeRecord.publish_fresh/6` raises `RuntimeError`, forcing 20 redeliveries even for deterministic refusals while leaving local ad-hoc fixes per handler.

## What Changes

- Define one four-way handler outcome contract (`ServiceRadar.Observability.PluginResultHandlerOutcome`) shared by every registered plugin result handler behind `PluginResultIngestor`:
  - `applied` (`:ok`): downstream domain writes succeeded;
  - `settled` (`{:settled, reason}` / `{:settled, reason, metadata}`): valid record deliberately not applied because its authority or ordering generation was superseded or withdrawn; acknowledged on first delivery, logged once, counted, with reported `service_status` preserved and marked `"settled"`;
  - `refused` (`{:refused, reason}` / `{:refused, reason, metadata}`): deterministic contract, ownership, capability, or schema violation that can never succeed on redelivery; dead-lettered on first delivery (`attempts=1`) into `TELEMETRY_EDGE_RECORD_DLQ_V1_BULK` under its specific bounded reason atom;
  - `retryable` (`{:error, reason}`): transient lookup, database, object-store, graph, or queue failure that may succeed on redelivery; retried with backoff up to `dead_letter_after_deliveries`.
- Define one mapping in `ServiceRadar.Edge.Projector` (`publish/3` and `project/4`) and `ServiceRadar.EventWriter.Processors.EdgeRecord` so `applied`, `settled`, `refused`, and `retryable` map cleanly onto ledger commits, `PipelineStats`, and first-delivery vs threshold dead-lettering without `RuntimeError` string wrapping.
- Define atomic multi-handler outcome precedence (`retryable > refused > applied > settled`) with per-handler status recording in `service_status.details["downstream_ingest"]`, preserving `#6505`'s mixed-aggregate AWX rule so un-ruled observations are never acknowledged unapplied.
- Preserve out-of-line staged artifacts (`ServiceRadar.NetworkConfig.PluginIngestor`) across `retryable` and `refused` (dead-lettered) deliveries, deleting staged objects only after `applied` or `settled` ledger commit (`Projector.committed/3`).
- Add anti-regression enforcement: unclassified `{:error, term}` handler returns default to `retryable` while emitting `[:serviceradar, :plugin_result, :handler, :unclassified_error]`, backed by a contract test suite covering closed reason sets per handler and missing-identity (`nil`, never `"nil"`) provenance lookups.
- Fold the one-off `#6505` (`awx_observation.superseded`) and `#6519` (`proxmox_result.assignment_withdrawn`) counters into one bounded telemetry metric (`[:serviceradar, :plugin_result, :handler, :outcome]`) during handler migration.

## Impact

- Affected specs:
  - `wasm-plugin-system`
  - `edge-producer-data-plane`
- Affected code (Stage 2 implementation, gated on proposal approval):
  - `elixir/serviceradar_core/lib/serviceradar/observability/plugin_result_handler_outcome.ex` (new)
  - `elixir/serviceradar_core/lib/serviceradar/observability/plugin_result_ingestor.ex`
  - `elixir/serviceradar_core/lib/serviceradar/edge/projector.ex`
  - `elixir/serviceradar_core/lib/serviceradar/edge/pipeline_stats.ex`
  - `elixir/serviceradar_core/lib/serviceradar/edge/contract_catalog.ex` (`projection_revision` bump where projection behavior changes)
  - `elixir/serviceradar_core/lib/serviceradar/edge/projectors/wasm_plugin_result.ex` (and catalogued projectors audited in `design.md`)
  - `elixir/serviceradar_core/lib/serviceradar/event_writer/processors/edge_record.ex`
  - All 11 handlers in `PluginResultIngestor.platform_contract_handlers/0` (`NetworkConfig.PluginIngestor`, `NetworkConfig.InterfaceCheckIngestor`, `Plugins.RunOverrideAckIngestor`, `Inventory.DeviceDiscoveryIngestor`, `Inventory.HypervisorEnrichmentIngestor`, `Inventory.ProxmoxEnrichmentIngestor` / `ProxmoxSourceScopeResolver`, `Inventory.VulnerabilityAdvisoryIngestor`, `WifiMap.BatchIngestor`, `Observability.ThreatIntelPluginIngestor`, `Camera.EventIngestor`, `Camera.InventoryIngestor`)
  - `elixir/serviceradar_core/lib/serviceradar/telemetry.ex`
