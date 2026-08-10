# Change: Update Plugin and Release Inventory Visibility

## Why
The release and plugin administration screens are currently showing too much historical inventory at once, which makes normal operations harder to read and does not match the intended bounded-retention behavior. Separately, assigned Wasm plugins such as UniFi and AlienVault can be loaded on agents without appearing in `/services`, which breaks the operator expectation that every loaded health-producing plugin is visible in the service inventory.

## What Changes
- Limit release-management UI inventory to the latest five published agent releases and the latest five repository releases.
- Enable demo object-store retention so mirrored agent release artifacts are cleaned up according to the latest-five release policy.
- Keep the First-party Repository Plugins release selector in the table header and paginate the selected release's plugin rows ten at a time.
- Define the service visibility contract for assigned Wasm plugins: each assigned health-producing plugin must publish a stable service/check identity and appear in `/services` with current health.
- Clean up device-details integration metadata so source-specific data is grouped into useful cards instead of one noisy key list.
- Ensure device details exposes important enrichment fields, including Armis device type/category/risk score and active/in-service state.
- Make device log loading bounded and empty-state aware instead of leaving the Logs tab in a slow loading/error state when no logs exist.
- Improve action launch/result UX so operators know where results land, Action History omits meaningless `nil` fields, and interface action targets include enough interface/module context.
- Correct action-launch authorization so operators with `northbound.actions.launch` can launch device/interface actions in the demo deployment, and unauthorized failures identify that exact missing permission.
- Treat release `command_ack_timeout` as a diagnostic state that can be superseded by later activation success instead of leaving a successful rollout looking stuck or failed.
- Prevent stale historical rollout attempts from making agent details show an obsolete desired version when the agent is already current on a newer release.
- Normalize Wasm plugin result statuses so plugin-reported failures become valid failed/unknown service states rather than invalid payload errors.
- Add explicit investigation and regression coverage for NetFlow map path loss and topology backbone island regressions.
- Add tests and documentation covering bounded release/plugin inventory and plugin-to-service visibility.

## Impact
- Affected specs:
  - `agent-release-management`
  - `age-graph`
  - `device-inventory`
  - `observability-netflow`
  - `plugin-results-ui`
  - `wasm-plugin-system`
- Related active specs/changes:
  - `add-object-store-retention`
  - `add-signed-wasm-plugin-import`
- Affected code:
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/agents_live/releases.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng/edge/release_source_importer.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/admin/plugin_package_live/index.ex`
  - `elixir/web-ng/test/phoenix/live/settings/agents_releases_live_test.exs`
  - `elixir/web-ng/test/phoenix/live/admin/plugin_package_live_test.exs`
  - `helm/serviceradar/values-demo.yaml`
  - Agent/gateway/plugin-result service status publication paths
  - `/services` UI/API data paths
  - action launch RBAC and northbound action authorization paths
  - device details metadata/logs/action-history UI paths
  - device enrichment/DIRE merge paths for Armis type and risk data
  - topology and NetFlow map data paths
