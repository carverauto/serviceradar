## Context

web-ng Settings navigation is assembled per page with no layout-level nav and no
single source of truth. Every Settings LiveView renders `<.settings_nav>` and
hand-picks its sub-nav; active state is computed by per-tab negated
`String.starts_with?/2` denylists (e.g. `sweep_profiles_active?/1` at
`elixir/web-ng/lib/serviceradar_web_ng_web/components/settings_components.ex:502`);
and `current_path` is threaded by hand. This produces four recurring breakages when
a page is added (namespace overload, per-page nav duplication, flex-wrap reflow,
orphaning). The mirror we want already exists in the codebase:
`ServiceRadar.Identity.RBAC.Catalog` is a clean declarative registry (one literal +
pure derived accessors) — we replicate that shape for navigation.

Constraints: this touches RBAC gating and dozens of routes, so it must not regress
authorization and must keep every existing settings URL deep-linkable. It ships
incrementally so current Settings keep working the whole time.

## Goals / Non-Goals

- Goals:
  - Make adding a Settings page a one-entry, zero-layout-risk change.
  - Structurally eliminate the four failure modes (not paper over them).
  - Adopt the mockup shell (icon rail, category switcher, view list, breadcrumbs,
    Ctrl+K palette, status cards).
  - Keep nav visibility and page authorization driven by the **same** permission key.
  - Migrate safely behind a per-user toggle with one source of truth throughout.
- Non-Goals:
  - No new RBAC permission keys (reference existing keys only).
  - No change to which users can access which page (visibility ⇔ existing Permit gate).
  - GAP pages (DNS Resolvers, VLAN Identification, Notification Webhooks, Alerting
    Templates, mTLS Certificates) are catalog placeholders here, built later.
  - No change to the app-level (non-Settings) navigation.

## Decisions

- **Decision: the catalog lives in web-ng, not core.** RBAC permissions are shared by
  web-ng + API, so `RBAC.Catalog` belongs in `serviceradar_core`. The nav catalog
  references web-ng-only concerns (LiveView modules, `~p` routes, heroicon names,
  FeatureFlags), so it lives at
  `elixir/web-ng/lib/serviceradar_web_ng_web/settings/catalog.ex`. It does **not**
  inline permission strings — its `permission:` field carries a key validated against
  `ServiceRadar.Identity.RBAC.Catalog.permission_keys/0`.
  - Alternatives considered: put nav in `RBAC.Catalog` (rejected — couples core to
    web-ng modules/routes); a DB-backed nav table (rejected — nav is code-shaped and
    wants compile-time + CI validation, not runtime state).

- **Decision: longest-prefix URI match resolves the active view.** `view_for_path/1`
  returns the view whose matching prefix is longest across all views, so
  `/settings/networks` (Sweep Profiles) and `/settings/networks/bmp` (BMP) coexist
  with no denylist. A new `/settings/networks/foo` matches whatever prefix is longest.
  - Alternatives considered: keep per-tab `*_active?` denylists (rejected — the very
    source of failure mode A); exact-match only (rejected — breaks nested detail routes).

- **Decision: an `on_mount` hook centralizes nav state.** `Settings.ShellHook` reads
  the connection URI in `handle_params` and assigns `:settings_active_view`,
  `:settings_active_category`, `:settings_breadcrumbs`, and the scope-filtered
  `:settings_nav_tree`. Pages render no nav chrome. This removes hand-typed
  `current_path` and per-page nav rendering, killing failure modes B and D.

- **Decision: the shell uses `overflow-x-auto`, never `flex-wrap`.** The switcher and
  view list scroll (or become a drawer/dropdown) rather than wrapping onto a second
  line, killing failure mode C.

- **Decision: nav visibility and page authorization share one key.** The catalog
  permission key feeds both `ServiceRadarWebNG.RBAC.can?/2` (nav pre-filter) and the
  existing `Permit.Phoenix.LiveView.AuthorizeHook` (page guard). Belt-and-suspenders:
  a deep-linked forbidden route is still denied at mount.

- **Decision: a CI validation test is the anti-breakage gate.** Category-FK validity,
  permission-key membership, unique route, unique `(category, id)`, ambiguity guard,
  and router-reachability orphan detector all fail the build, never production.

## Risks / Trade-offs

- RBAC gating drift (nav shows a view the user can't open, or hides one they can)
  → the same catalog key drives both layers; the validation test cross-checks every
  `view.permission` against `RBAC.Catalog` and the Authorization mapping.
- Feature-flag / capability parity (host-keys, desktop-targets, recordings,
  collectors are gated today) → the view schema carries `feature_flag` and
  `capability`; the shell honors them.
- Merged `/admin/*` routes 404 → add GET redirects to canonical `/settings/*`; the
  validation test asserts catalog route strings are byte-identical to router routes.
- Responsive/mobile width (rail + list + content is wide) → view list collapses to a
  drawer, switcher to a dropdown, status strip wraps/hides.
- Keyboard a11y regressions in the palette (focus trap, ESC, arrows, restore focus)
  and switcher (roving tabindex, `aria-current`) → covered by tests.
- Toggle drift while both UIs coexist → the legacy tab bar is fed from the catalog via
  the adapter, so a mid-migration page appears in both chromes; the adapter is kept
  until phase 4 cleanup.
- GAP-page dead menu items → list a GAP view only once its LiveView exists, or show a
  clearly-labeled placeholder.

## Migration Plan

- Phase 0 — catalog + validation test + `settings_ui` pref (default `:original`) +
  dormant `ShellHook` + legacy-adapter re-point. Zero UI change.
- Phase 1 — build `Settings.Shell`; activate `ShellHook` for `:catalog`; migrate
  **Audit & System Log** (pilot). Legacy users unaffected.
- Phase 2 — migrate the remaining six categories; execute MERGEs (redirects), MOVEs,
  RENAMEs; rescue orphan routes; delete each category's legacy tab builder + denylists.
- Phase 3 — Ctrl+K palette, status cards, responsive/a11y, GAP pages; flip
  `settings_ui` default to `:catalog`.
- Phase 4 — delete legacy `SettingsComponents` nav + `admin_nav` duplication; remove
  the toggle once telemetry shows no fallback usage.
- Rollback: at any phase, `settings_ui: :original` (or reverting the default) restores
  the untouched legacy chrome; the adapter keeps both chromes consistent.

## Open Questions

- **System Event Logs** target: point at the existing Audit `SecurityEvent` stream, or
  deep-link the app-level log/event explorers (`/observability` / `/logs`, `/events`)?
- **Subnet Mapping**: a filtered view over sweep groups (`/settings/networks`) or a new
  GAP page?
- Where the visible toggle lives besides the shell header — confirm `/settings/profile`.
