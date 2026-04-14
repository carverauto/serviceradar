# Change: Restore Armis northbound availability updates

## Why

- The current embedded Armis sync flow discovers devices and publishes them into ServiceRadar, but it stops at inbound discovery.
- The current agent runtime still preserves Armis identity on discovered devices via `armis_device_id` metadata, and `models.SourceConfig` still carries `custom_field`, so the prerequisites for northbound updates are still present.
- Historical Armis integration code previously supported a reconciliation path that queried ServiceRadar device state and pushed bulk custom-property updates back to Armis using `/api/v1/devices/custom-properties/_bulk/`.
- Since the sync integration moved into the embedded agent runtime (`go/pkg/agent/sync_runtime.go`), that northbound reconciliation path is no longer active, so Armis never receives the post-sweep availability status that operators rely on.
- The existing web-ng integrations UI already surfaces inbound sync status fields such as `last_sync_result`, `last_sync_at`, and `last_error_message`, but it does not model or expose a first-class northbound update schedule, run history, metrics, or event trail.
- The old architecture leaned on NATS KV and sync-side plumbing that is no longer the right source of truth. The revived design needs to be database-backed, Ash/AshOban-native, and observable from the UI and event pipeline.

## What Changes

- Add a northbound Armis reconciliation/update cycle so ServiceRadar can push device availability state back to Armis after ICMP/TCP sweep results are known.
- Move northbound orchestration to database-backed scheduling and state tracking, using AshOban for recurring and on-demand Armis update jobs rather than reviving the old NATS KV-driven path.
- Correlate outbound updates by `armis_device_id`, using the latest consolidated availability for each Armis-discovered device rather than raw per-IP sweep rows.
- Reuse the configured Armis source endpoint/auth and `custom_field` target, and send updates through Armis's bulk custom-properties API.
- Extend the Settings -> Network -> Integrations experience so operators can configure the northbound update cadence, view run status/error details, and understand whether Armis discovery is working even when outbound updates are failing.
- Record per-run metrics and create success/failure events for northbound Armis update jobs so operators can observe behavior from the database-backed jobs and events surfaces.

## Impact

- Affected specs: `sync-service-integrations`, `build-web-ui`, `job-scheduling`, `ash-observability`
- Affected code:
  - embedded Armis sync/runtime and availability-correlation code
  - Ash/AshOban resources or actions that schedule and execute Armis northbound updates
  - integrations settings UI and jobs UI in `elixir/web-ng`
  - database-backed run history / status / metrics / event emission for Armis update jobs
  - Armis HTTP client/update logic (likely restored/ported from historical `pkg/sync/integrations/armis/armis_updater.go` behavior)
