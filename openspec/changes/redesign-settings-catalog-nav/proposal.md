# Change: Redesign web-ng Settings navigation as a declarative catalog

## Why

The web-ng Settings area has no single source of truth for its navigation and no
layout-level nav. Chrome is assembled per page: every Settings LiveView manually
renders `<.settings_nav>` (the top tab row) and hand-picks which sub-nav component
to also render, and each page passes its own `current_path`. Active-tab state is
computed by hand-written, per-tab, negated `String.starts_with?/2` denylists
(for example `sweep_profiles_active?/1` at
`elixir/web-ng/lib/serviceradar_web_ng_web/components/settings_components.ex:502`
enumerates and negates ten sibling prefixes). Adding a Settings page therefore
breaks navigation in four recurring ways:

- **A. Namespace overload.** Views that share a URI root (`/settings/networks` for
  Sweep Profiles vs. `/settings/networks/*` children) can only be told apart by
  extending a negated `String.starts_with?/2` denylist. A new `/settings/networks/foo`
  silently highlights the parent until every denylist is updated by hand.
- **B. Per-page nav duplication.** Because each page renders its own nav, sibling
  pages disagree (one page renders `events_nav`, its sibling forgets to), so the
  nav visibly changes between pages that should share it.
- **C. flex-wrap reflow.** The tab rows are `flex flex-wrap`, so a 13th category or
  a long label wraps onto a second line and shoves the sub-nav row down, shifting
  the whole layout.
- **D. Orphaning + hand-typed `current_path`.** `current_path` is threaded by hand
  (three different ways) and easy to mistype; a new route with no nav wiring becomes
  an orphan reachable only by URL, and nothing catches it.

Because these are structural, every future Settings page is at risk. We want a
catalog such that adding a page **cannot** break the nav, and we want to adopt the
mockup look-and-feel (persistent icon rail + topbar category switcher + left view
list + breadcrumbs + Ctrl+K palette + status cards).

## What Changes

- **One declarative source of truth.** Add `ServiceRadarWebNGWeb.Settings.Catalog`
  (in web-ng, not core — it references LiveView modules, `~p` routes, heroicon names,
  and FeatureFlags). It is modeled exactly like
  `ServiceRadar.Identity.RBAC.Catalog`: one `@categories` literal + one flat `@views`
  literal (uniform map schema) plus pure derived accessors. Its `permission:` field
  carries a **key** that must exist in `ServiceRadar.Identity.RBAC.Catalog.permission_keys/0`
  (a symbolic reference, never an inlined string).
- **Every nav surface renders from the catalog.** The icon rail, topbar category
  switcher, left view list, breadcrumbs, and Ctrl+K palette all derive from the
  catalog, so adding a page is **one** map entry with zero layout risk.
- **Deterministic active-view resolution.** An `on_mount` hook
  (`Settings.ShellHook`) reads the connection URI in `handle_params` and calls
  `Catalog.view_for_path/1`, which returns the **longest-prefix** winner across all
  views. This replaces `current_path` threading and every negated
  `String.starts_with?/2` denylist, structurally killing failure modes A, B, and D.
- **A CI validation gate.** A test (and optional compile-time assert) fails the
  build — never production — when the catalog is malformed: an orphan detector
  (every `view.live_view` is routed in the Phoenix router, and routed Settings views
  have a catalog entry), an ambiguity guard (no two views share an identical match
  prefix), a permission-key check (every `view.permission` is in
  `RBAC.Catalog.permission_keys/0`), category-FK validity, and unique route +
  unique `(category, id)`.
- **New shell.** `Settings.Shell.settings_shell/1` (daisyUI + Tailwind + LiveView),
  a CSS grid `[icon-rail w-16][view-list w-64][content]`: icon rail (reuses the
  existing `.sr-ops-sidebar` styling), topbar category switcher (daisyUI
  `tabs tabs-boxed` inside `overflow-x-auto` — horizontal scroll, **not** `flex-wrap`,
  which kills failure mode C; collapses to a dropdown under `lg`), left view list
  (daisyUI `menu`, a drawer on mobile), breadcrumbs (daisyUI `breadcrumbs`),
  status-card strip (daisyUI `stats`), and a Ctrl+K command palette (`<dialog>`
  opened via `phx-window-keydown` + a JS hook, fuzzy-filtering `palette_index/1`).
- **RBAC gating from catalog keys.** Every nav list is pre-filtered with
  `ServiceRadarWebNG.RBAC.can?(scope, view.permission)` (plus feature-flag and
  capability checks), so a user only sees permitted, enabled views. Page
  authorization is unchanged: `Permit.Phoenix.LiveView.AuthorizeHook` still guards
  the pages, and the **same** catalog permission key feeds both nav visibility and
  the mutation guard.
- **Phased migration behind a per-user Original-UI toggle.** A `settings_ui`
  preference (`:original | :catalog`, default `:original`) lets current Settings keep
  working untouched while categories migrate one at a time. During migration the
  legacy tab bar is re-pointed at the catalog through a thin adapter, so there is
  exactly one source of truth even before the visual cutover. The toggle and the
  legacy chrome are removed after adoption.

## Impact

- Affected specs: `settings-navigation` (new capability).
- Affected code (web-ng):
  - New: `elixir/web-ng/lib/serviceradar_web_ng_web/settings/catalog.ex`,
    `.../settings/shell_hook.ex`, `.../settings/shell.ex`, `.../settings/command_palette.*`
    (JS hook), plus a catalog validation test.
  - Modified: `router.ex` (attach `Settings.ShellHook` on the Settings live_sessions;
    add redirects for merged `/admin/*` paths), and the Settings LiveViews (drop
    `current_path`, `settings_nav`, and per-page sub-nav rendering).
  - Retired at cutover: `components/settings_components.ex` legacy tab builders and
    `*_active?` / `sweep_*_active?` denylists; parallel `admin_nav` duplication.
- Affected RBAC: no new permission keys required; the catalog references existing
  keys in `ServiceRadar.Identity.RBAC.Catalog`. GAP pages (Notification Webhooks,
  etc.) reuse existing `northbound.*` keys so the catalog key is ready before the
  page exists.
- User-facing: settings routes stay byte-identical and deep-linkable; merged
  `/admin/*` routes gain redirects to their canonical `/settings/*` targets.
