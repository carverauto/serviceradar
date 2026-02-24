# Change: Refactor RBAC Access Control UI Into A Single-Page Policy Editor

## Why
- The current Access Control experience is cluttered, hard to scan, and does not match the mental model admins have when defining permissions.
- Admins need to compare and edit multiple role profiles quickly without navigating through unrelated UI chrome (stats blocks, legend callouts, duplicated CTAs).
- The UI should make RBAC configuration feel like a "policy editor" rather than a collection of loosely-related cards and tables.

## What Changes
- Replace the current `/settings/auth/access` layout with a clean, admin-focused RBAC policy editor dashboard.
- Present each role profile (viewer/admin/operator plus any custom profiles) as a dedicated card in a horizontally stacked strip.
- Inside each profile card, render a permissions grid (resources x actions) with checkboxes, enabling fast editing and comparison across profiles.
- Remove the persistent legend and other non-essential UI elements; provide contextual help only when needed.
- Improve save/dirty-state behavior and error handling so it is obvious what changed and what will be persisted.
- Keep built-in profiles clone-only; allow custom profiles to be created, edited, and deleted from the same page.

## Impact
- Affected specs: `build-web-ui` (added requirement for RBAC policy editor dashboard UI).
- Affected code: `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/access_control_live.ex` and associated components/styles.
- Affected APIs: may introduce an aggregated "RBAC editor payload" endpoint (catalog + profiles + assignment counts) to reduce UI round-trips; existing endpoints remain supported for backward compatibility.
- UX breaking change: existing Access Control page layout will be replaced (functionality retained, presentation and interaction model changed).

