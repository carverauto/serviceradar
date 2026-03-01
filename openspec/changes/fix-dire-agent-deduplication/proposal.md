# Change: Fix DIRE agent deduplication — register agent_id in all ingestion paths

## Why

GitHub Issue: #2800

Agents are not being deduplicated by DIRE. The `k8s-agent` (running in a Kubernetes pod with ephemeral IPs) has created 37+ duplicate device records — one per pod restart. Each time the pod gets a new IP, DIRE creates a new device instead of resolving to the existing one.

Root cause: while `add-dire-agent-id-identifier` added `agent_id` support to the DIRE core (`IdentityReconciler`), **no caller ever registers `agent_id` in `device_identifiers`**. The DB has zero `agent_id` entries in `device_identifiers`. Without registration, DIRE's lookup-by-strong-identifier always misses, and resolution falls back to IP lookup — which creates a new device for each new IP.

Three gaps:
1. `AgentGatewaySync.ensure_device_for_agent` — calls `resolve_device_id` but never `register_identifiers`
2. `SyncIngestor.build_identifier_records` — registers armis, integration, netbox, mac but skips `agent_id`
3. `SyncIngestor.cached_device_id` — checks armis, integration, netbox, mac cache but skips `agent_id`

## What Changes

- **AgentGatewaySync** calls `register_identifiers` after device creation/upsert so the agent_id is persisted in `device_identifiers`
- **SyncIngestor** adds `:agent_id` to `build_identifier_records` and `cached_device_id` so sync ingestion both registers and caches agent_id lookups
- **Data cleanup** consolidates the 37+ duplicate k8s-agent devices into a single canonical device, reassigning all associated records
- **Backfill** registers `agent_id` in `device_identifiers` for existing devices that have `agent_id` set on `ocsf_devices` but no corresponding identifier row

## Impact

- Affected specs: `device-identity-reconciliation`
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/edge/agent_gateway_sync.ex`
  - `elixir/serviceradar_core/lib/serviceradar/inventory/sync_ingestor.ex`
  - `elixir/serviceradar_core/lib/serviceradar/inventory/identity_reconciler.ex` (minor — no core changes needed)
