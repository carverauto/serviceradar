# Change: Update Plugin and Release Inventory Visibility

## Why
The release and plugin administration screens are currently showing too much historical inventory at once, which makes normal operations harder to read and does not match the intended bounded-retention behavior. Separately, assigned Wasm plugins such as UniFi and AlienVault can be loaded on agents without appearing in `/services`, which breaks the operator expectation that every loaded health-producing plugin is visible in the service inventory.

## What Changes
- Limit release-management UI inventory to the latest five published agent releases and the latest five repository releases.
- Enable demo object-store retention so mirrored agent release artifacts are cleaned up according to the latest-five release policy.
- Keep the First-party Repository Plugins release selector in the table header and paginate the selected release's plugin rows ten at a time.
- Define the service visibility contract for assigned Wasm plugins: each assigned health-producing plugin must publish a stable service/check identity and appear in `/services` with current health.
- Add tests and documentation covering bounded release/plugin inventory and plugin-to-service visibility.

## Impact
- Affected specs:
  - `agent-release-management`
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
