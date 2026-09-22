# Change: Honor endpoint inventory cadence when reconcile floor is due

## Why
ScaLibr (and the shared endpoint-inventory cache) is configured for a 24h collection cadence, but the systemd timer wakes hourly. A server reconcile-floor directive currently forces a full filesystem walk on every wakeup instead of a full *upload* of the already-cached package set. Core then keeps re-sending that directive on later heartbeats, so the expensive walk never returns to once per day.

## What Changes
- Treat cadence as the owner of **collection** (the package-db / filesystem walk). An outstanding reconcile floor SHALL force a full **upload** of the cached package set, not a new walk, when sources are unchanged and cadence has not elapsed.
- Stop re-emitting `endpoint_inventory.reconcile_floor` on duplicate/short-circuit ingest of a scan that already has `reconcile_floor_due`.
- Acknowledge a successful full upload before applying a new reconcile directive on the same gateway response, so an ack cannot be overwritten by a leftover floor stamp.

## Impact
- Affected specs: endpoint-inventory-reconcile
- Affected code:
  - `go/pkg/endpointinventory/cache_policy.go`
  - `go/pkg/endpointinventory/cache_commit.go` (cached reconcile replay)
  - `go/pkg/endpointinventory/collect.go`
  - `go/pkg/scalibrinventory/adapter.go`
  - `go/pkg/agent/endpoint_inventory_upload_ack.go`
  - `elixir/serviceradar_core/lib/serviceradar/inventory/endpoint_inventory_ingestor.ex`
  - `addons/scalibr-endpoint-inventory/addon.yaml` (version bump)
- Related: `add-scalibr-scan-skip-directories` (walk cost). This change is why the walk still ran every hour after skips.
