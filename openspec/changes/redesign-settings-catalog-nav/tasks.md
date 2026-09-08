# Tasks: Redesign web-ng Settings navigation as a declarative catalog

## 1. Phase 0 — Foundation (zero UI change, toggle default `:original`)
- [ ] 1.1 Add `ServiceRadarWebNGWeb.Settings.Catalog` with the `@categories` and flat
      `@views` literals (uniform map schema: category = `id/title/icon/order/rail_group/permission/feature_flag`;
      view = `id/category/title/icon/route/live_view/permission/order/feature_flag/capability/match_prefixes/keywords/badge/hidden_from_nav`).
- [ ] 1.2 Implement the pure derived accessors: `categories/0`, `views/0`,
      `views_for_category/1`, `visible_categories/1`, `visible_views/2`,
      `view_for_path/1` (longest-prefix winner), `category_for_view/1`,
      `breadcrumbs_for_path/1`, `palette_index/1`, `rail_groups/0`.
- [ ] 1.3 Add the catalog validation test (the anti-breakage gate) and wire it into CI:
      every `view.category` exists in `@categories`; every `view.permission` ∈
      `ServiceRadar.Identity.RBAC.Catalog.permission_keys/0`; route unique; `(category, id)`
      unique; ambiguity guard (no two views share an identical match prefix); orphan
      detector (every `view.live_view` is reachable in the Phoenix router).
- [ ] 1.4 Add the `settings_ui` user preference (`:original | :catalog`, default
      `:original`), persisted on the User and mirrored into session/scope assigns.
- [ ] 1.5 Add the dormant `Settings.ShellHook` `on_mount` to both Settings
      `live_session`s; while `:original` it is a no-op.
- [ ] 1.6 Re-point `SettingsComponents.settings_tabs/2` to derive its tab maps from
      the catalog via a thin adapter, so the legacy chrome already reads one source of truth.

## 2. Phase 1 — Shell + one category behind the toggle
- [ ] 2.1 Build `Settings.Shell.settings_shell/1`: CSS grid `[icon-rail w-16][view-list w-64][content]`.
- [ ] 2.2 Icon rail from `Catalog.rail_groups/0`, reusing `.sr-ops-sidebar` styling, with `aria-current`.
- [ ] 2.3 Topbar category switcher: daisyUI `tabs tabs-boxed` inside `overflow-x-auto`
      (horizontal scroll, not `flex-wrap`); collapses to a dropdown under `lg`.
- [ ] 2.4 Left view list: daisyUI `menu` from `Catalog.visible_views/2`, active =
      `@settings_active_view`; collapses to a drawer on mobile.
- [ ] 2.5 Breadcrumbs: daisyUI `breadcrumbs` from `@settings_breadcrumbs`
      (`Settings > Category > View`).
- [ ] 2.6 Activate `Settings.ShellHook` for `settings_ui: :catalog`: in `handle_params`
      resolve `:settings_active_view`, `:settings_active_category`, `:settings_breadcrumbs`,
      and the scope-filtered `:settings_nav_tree` from the URI via `view_for_path/1`.
- [ ] 2.7 Migrate the **Audit & System Log** category (smallest, cleanest sub-nav, no
      `/settings/networks` overlap): its pages drop `settings_nav`, `audit_nav`, and `current_path`.
- [ ] 2.8 Verify `:original` users are unaffected and `:catalog` users see the new shell for Audit only.

## 3. Phase 2 — Migrate the remaining six categories
- [ ] 3.1 Migrate Core Cluster, Discovery & Sweeps, Edge Ops, Network Services,
      Mail & Alerts, and Security & Auth view-by-view; each migrated page deletes its
      hand-rolled `settings_nav` / `*_nav` / `@current_path`.
- [ ] 3.2 Execute the MERGEs: redirect `/admin/cluster`, `/admin/plugins`,
      `/admin/addons`, `/admin/edge-packages` (and other `/admin/*` duplicates) to their
      canonical `/settings/*` routes.
- [ ] 3.3 Execute the MOVEs: Flows, BMP, MTR, Integrations, FieldSurvey, Threat Intel,
      Host Keys, Gateways, Ansible, and Jobs into their catalog categories.
- [ ] 3.4 Rescue the orphan routes as catalog entries: `user-groups`, `api-credentials`,
      `cli-sessions`, `cli-auth`, and `profile` (as `hidden_from_nav: true`).
- [ ] 3.5 As each category finishes, delete its legacy `*_tab` builder, `*_nav`
      component, and `*_active?` / `sweep_*_active?` denylists.

## 4. Phase 3 — Polish + cutover
- [ ] 4.1 Command palette: `palette_index/1` + a JS hook (`<dialog>` opened by Ctrl+K
      via `phx-window-keydown`, focus trap, ESC, arrow-key roving, kbd hints);
      Enter `push_navigate`s to the view route.
- [ ] 4.2 Status-card strip via daisyUI `stats` (cluster health, connected agents,
      pending jobs, active alerts), degrading gracefully.
- [ ] 4.3 Responsive collapse (mobile drawer + switcher dropdown), full a11y
      (`aria-current`, roving tabindex), and verify every route is deep-linkable/bookmarkable.
- [ ] 4.4 Build the GAP pages as catalog entries once their LiveViews exist: DNS
      Resolvers, VLAN Identification, Notification Webhooks, Alerting Templates, mTLS Certificates.
- [ ] 4.5 Flip the `settings_ui` default to `:catalog`.

## 5. Phase 4 — Cleanup (post-adoption)
- [ ] 5.1 Delete the legacy `SettingsComponents` nav and the parallel `admin_nav` duplication.
- [ ] 5.2 Remove the Original-UI toggle once telemetry shows no fallback usage.

## 6. Validation
- [ ] 6.1 Run `openspec validate redesign-settings-catalog-nav --strict` and resolve issues.
