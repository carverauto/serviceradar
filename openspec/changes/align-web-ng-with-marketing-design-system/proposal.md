# Change: Align web-ng with marketing/control design system

## Why

ServiceRadar’s public surfaces (marketing `serviceradar-web`, control plane) already share a deliberate design system: Avenir Next, `sr-*` semantic tokens, bordered brand mark, sticky shell chrome, and **no daisyUI**. Product web-ng still uses the older Nocturne + daisyUI stack (`btn`, `menu`, `drawer`, `dropdown`, base theme vars). Operators see a different product family when they move from `serviceradar.cloud` → control → the main app.

This workstream unifies brand and shell chrome first, then migrates primitives off daisyUI to Tailwind v4 + shared tokens so future UI work matches marketing/control by default.

## What Changes

- Introduce shared **ServiceRadar design tokens** (`sr-*` colors, radii, shadows, fonts, z-index) into web-ng, aligned with marketing and control.
- Align **authenticated ops topbar** and **public/standard shell topbar** with marketing brand mark, type, spacing, and sticky chrome (ops keeps density-oriented cyan accents for charts/nav active states).
- Phase out **daisyUI** for shell chrome and shared primitives (`theme_toggle`, profile menu, then buttons/forms/menus/drawers), replacing with Tailwind utilities + Phoenix function components.
- Update layout tests and any specs that currently require daisyUI themes or components for shell behavior.
- Preserve existing routes, SRQL topbar placement, and operations sidebar icon rail behavior while restyling.
- **BREAKING (visual only):** Nocturne daisy base tokens remain during migration; final phase may retune primary accents toward brand green on non-ops surfaces. No intentional API/route breaks.

### Out of scope (follow-ups)

- Full retheme of every LiveView page in one change (pages migrate as primitives land).
- Settings catalog shell redesign (see `redesign-settings-catalog-nav` — coordinate when both touch shared shell).
- Marketing or control plane code changes (source of truth stays those apps).
- Local arm64 Docker image builds; web-ng images continue via Bazel/CI only.

## Impact

- Affected specs: `build-web-ui`, `web-ng-build`
- Affected code:
  - `elixir/web-ng/assets/css/app.css` (tokens, shell CSS, eventual daisy plugin removal)
  - `elixir/web-ng/lib/serviceradar_web_ng_web/components/layouts.ex` (ops + standard shells)
  - `elixir/web-ng/lib/serviceradar_web_ng_web/components/ui_components.ex` and related primitives
  - `elixir/web-ng/priv/static/images/` (brand assets, e.g. `logo-animated.svg`)
  - LiveView/layout tests under `elixir/web-ng/test/`
- Coordination: any open change that hard-codes daisyUI shell patterns (e.g. settings nav) should adopt tokens/primitives from this change rather than reintroducing daisy shell chrome.
- Work branch: `ui/web-ng-align-marketing` (worktree `~/src/serviceradar-web-ng-ui`, base `origin/staging`)

## Status

- **Proposal for approval** so the full task list and phases are tracked.
- **Phase 1 (tokens + topbar)** is already started on the branch so the proposal does not invent empty work; remaining tasks are gated on approval of the overall plan.
