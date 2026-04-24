# Change: Add `agent_id` as highest-priority strong identifier in DIRE

## Why

GitHub Issue: #2758

When a Kubernetes agent pod restarts and receives a new IP address, DIRE creates a new device record instead of resolving to the existing one. The `agent_id` is a stable, mTLS-validated identifier that persists across pod restarts, but DIRE does not currently recognize it as a strong identifier. Device resolution falls back to IP lookup, which fails with the new IP, generating a duplicate `sr:<uuid>` device.

## What Changes

- **New identifier type `agent_id`** added to `DeviceIdentifier` resource as highest-priority strong identifier (priority 0, above `armis_device_id`)
- **Identity reconciler updated** to extract, match, hash, and register `agent_id` from `metadata["agent_id"]` throughout the full resolution pipeline
- **Agent gateway sync threads `agent_id`** into the device update metadata so DIRE can use it during enrollment and heartbeat flows
- **No DB migration required** because `identifier_type` is stored as TEXT with application-level `one_of` constraint only

## Impact

- Affected specs: `device-identity-reconciliation`
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/inventory/device_identifier.ex`
  - `elixir/serviceradar_core/lib/serviceradar/inventory/identity_reconciler.ex`
  - `elixir/serviceradar_core/lib/serviceradar/edge/agent_gateway_sync.ex`
  - `elixir/serviceradar_core/test/serviceradar/inventory/identity_reconciler_identifiers_test.exs`
