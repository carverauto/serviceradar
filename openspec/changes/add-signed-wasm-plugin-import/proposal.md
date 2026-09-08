# Change: Add signed first-party Wasm plugin repository import

## Why
First-party Wasm plugins are already built, signed, and published by the repository, but operators still need a manual plugin-package import path before those plugins appear in ServiceRadar. Agent release management already has a Forgejo release import pattern; first-party Wasm plugins need the same trusted repository-driven flow so approved signed plugins can be discovered, mirrored, reviewed, and assigned from the UI.

## What Changes
- Add a Forgejo-backed first-party Wasm plugin import catalog that discovers repository releases and plugin import metadata.
- Verify published Wasm plugin OCI artifacts using Cosign signatures and the existing upload-signature metadata before mirroring bundles into ServiceRadar-managed plugin storage.
- Reuse the plugin package staged review lifecycle so imported plugins are visible but not assignable until approved.
- Extend the plugin UI to show repository-discovered first-party plugins, import status, verification status, source release, available versions, and actions to import or approve.
- Add a scheduled/manual sync path that can automatically import newly trusted first-party plugin versions from the configured ServiceRadar repository.

## Impact
- Affected specs: `wasm-plugin-system`, `wasm-plugin-builds`
- Affected code:
  - `.forgejo/workflows/release.yml`
  - `scripts/push_all_wasm_plugins.sh`
  - `scripts/sign-wasm-plugin-publish.sh`
  - `scripts/verify-wasm-plugin-publish.sh`
  - `elixir/serviceradar_core/lib/serviceradar/plugins/**`
  - `elixir/serviceradar_core/priv/repo/migrations/**`
  - `elixir/web-ng/lib/serviceradar_web_ng/plugins/**`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/admin/plugin_package_live/**`
  - `elixir/web-ng/test/**`
  - `docs/docs/wasm-plugins.md`
