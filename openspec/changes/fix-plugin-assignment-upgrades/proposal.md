# Change: Fix plugin assignment upgrades

## Why
Operators can currently get trapped while moving an agent to the latest plugin version: deleting an assignment can crash the LiveView when the delete path returns `:ok`, and trying to add the newer package can fail with duplicate-assignment validation because the existing enabled assignment still owns the agent/plugin pair.

The UI also makes version management indirect. A user has to navigate package versions, remove assignments, and recreate them manually instead of seeing that an assigned plugin has a newer approved version and upgrading it in place.

## What Changes
- Normalize plugin assignment deletion handling so successful deletes never crash the LiveView, regardless of whether Ash returns `:ok` or `{:ok, assignment}`.
- Add an explicit assignment upgrade flow for enabled agent/plugin assignments.
- Show upgrade actions next to each loaded assignment when a newer approved package exists for the same `plugin_id`.
- Allow operators to upgrade to the latest approved version or select a specific approved version.
- Preserve assignment configuration, interval, timeout, source metadata, and overrides when the target package schema remains compatible.
- Require clear validation and user feedback when a target version requires config changes or when the assignment is policy-owned and cannot be manually upgraded.
- Improve duplicate-assignment feedback so users are guided to upgrade or replace the existing assignment instead of hitting a generic create failure.

## Impact
- Affected specs: `plugin-configuration-ui`
- Affected code:
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/admin/plugin_package_live/index.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng/plugins/assignments.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng/plugins/packages.ex`
  - `elixir/serviceradar_core/lib/serviceradar/plugins/plugin_assignment.ex`
  - `elixir/serviceradar_core/lib/serviceradar/plugins/validations/*`
  - LiveView/Ash tests for plugin assignment create, delete, and upgrade behavior
- Data impact: no new tables expected; may add an Ash update action for controlled package replacement if existing generic update semantics are insufficient.
