# Change: Fix services plugin status read model

## Why
The `/services` page is meant to show the latest plugin check per service immediately, but current behavior is inconsistent: after reload, healthy checks can remain stale or unavailable until the next agent status push, assignment placeholder rows can appear as failures after real plugin results already exist, and several first-party plugins now fail due to missing runtime configuration or Wasm/runtime regressions.

Operators need `/services` to be a durable current-state view backed by Postgres, not a page that depends on the next check cycle to look correct.

## What Changes
- Make `platform.service_state` the authoritative current-state read model for active plugin service cards and summaries.
- Ensure plugin result ingestion updates both historical `service_status` and current `service_state` with one stable identity.
- Prevent assignment reconciliation from overwriting newer real plugin results with `plugin assignment pending result`.
- Backfill or repair current-state rows from recent `service_status` history when the read model is missing or stale.
- Audit and fix first-party plugin assignments/config materialization so required runtime fields such as AWX `base_url`/`api_token` and Proxmox target credentials are present before execution.
- Enforce one approved package version per plugin ID and disable assignments for superseded package versions.
- Add regression coverage for first-party scheduled plugins and `/services` reload behavior.

## Impact
- Affected specs: `plugin-results-ui`, `wasm-plugin-system`
- Affected code:
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/service_live/index.ex`
  - `elixir/serviceradar_core/lib/serviceradar/observability/service_state_registry.ex`
  - `elixir/serviceradar_core/lib/serviceradar/observability/plugin_result_ingestor.ex`
  - `elixir/serviceradar_core/lib/serviceradar/results_router.ex`
  - `elixir/serviceradar_core/lib/serviceradar/edge/agent_config_generator.ex`
  - `elixir/serviceradar_core/lib/serviceradar/credentials/plugin_assignment_materializer.ex`
  - `elixir/serviceradar_core/lib/serviceradar/plugins/plugin_package.ex`
  - `elixir/serviceradar_core/priv/repo/migrations/*`
  - `elixir/web-ng/lib/serviceradar_web_ng/plugins/packages.ex`
  - `go/pkg/agent/plugin_runtime.go`
  - `go/cmd/wasm-plugins/{awx,proxmox,alienvault-otx,dusk-checker,unifi-protect,sample-northbound}`
- Data impact: add a partial unique index in the `platform` schema so only one package per plugin can be `approved`; superseded approved packages are revoked and their assignments disabled during migration.
