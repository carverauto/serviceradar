## ADDED Requirements

### Requirement: Catalog is the single source of truth for Settings navigation

The web-ng Settings navigation SHALL be defined by exactly one declarative module,
`ServiceRadarWebNGWeb.Settings.Catalog`, holding one `@categories` literal and one
flat `@views` literal with a uniform map schema, plus pure derived accessors. Every
Settings navigation surface — the icon rail, the topbar category switcher, the left
view list, the breadcrumbs, and the Ctrl+K command palette — SHALL render entirely
from that catalog. No Settings page SHALL define its own navigation, and no
navigation surface SHALL be derived from any other source.

#### Scenario: All nav surfaces render from the catalog

- **GIVEN** the `Settings.Catalog` module defines the categories and views
- **WHEN** any Settings page renders under the new shell
- **THEN** the icon rail, category switcher, view list, breadcrumbs, and command
  palette are all derived from `Settings.Catalog`
- **AND** no Settings LiveView renders its own navigation chrome or threads a
  hand-typed `current_path`

#### Scenario: Catalog references RBAC keys symbolically, not inline strings

- **GIVEN** a view entry in `Settings.Catalog`
- **WHEN** its `permission:` field is set
- **THEN** the field carries a key that exists in
  `ServiceRadar.Identity.RBAC.Catalog.permission_keys/0`
- **AND** the catalog does not inline permission definitions or duplicate RBAC data

### Requirement: Adding a Settings view is one catalog entry guarded by a CI validation gate

Adding a Settings page SHALL require adding exactly one entry to the `@views` literal
and nothing else for the page to appear in every navigation surface. A CI validation
test SHALL fail the build (never production) when the catalog is malformed. The gate
SHALL enforce: every `view.category` exists in `@categories`; every `view.permission`
is in `ServiceRadar.Identity.RBAC.Catalog.permission_keys/0`; each `route` is unique;
each `(category, id)` pair is unique; no two views share an identical match prefix
(ambiguity guard); and every `view.live_view` is reachable in the Phoenix router
(orphan detector).

#### Scenario: A well-formed new view appears everywhere from one entry

- **GIVEN** a developer adds one valid entry to the `@views` literal
- **WHEN** the application renders the Settings shell
- **THEN** the new view appears in its category's view list, breadcrumbs, and the
  command palette without any other code change

#### Scenario: A misfiled category fails CI

- **WHEN** a view entry references a `category` not present in `@categories`
- **THEN** the catalog validation test fails
- **AND** the build fails before the change can be deployed

#### Scenario: An unknown permission key fails CI

- **WHEN** a view entry's `permission` is not in `RBAC.Catalog.permission_keys/0`
- **THEN** the catalog validation test fails

#### Scenario: An orphaned route fails CI

- **WHEN** a view entry's `live_view` is not reachable in the Phoenix router
- **THEN** the orphan detector in the validation test fails the build

#### Scenario: An ambiguous match prefix fails CI

- **WHEN** two view entries resolve to an identical match prefix
- **THEN** the ambiguity guard in the validation test fails the build

### Requirement: Navigation renders only views the user is permitted to see

Every navigation list SHALL be pre-filtered by RBAC so a user only sees views they
are permitted to open and that are enabled by feature flags and capabilities. The
navigation filter SHALL use the same catalog permission key that gates the page, so
navigation visibility and page authorization never disagree. Page authorization SHALL
remain enforced by `Permit.Phoenix.LiveView.AuthorizeHook` at mount regardless of
navigation.

#### Scenario: An unpermitted view is hidden from nav

- **GIVEN** a user whose scope lacks a view's `permission`
- **WHEN** the Settings shell renders
- **THEN** that view does not appear in the icon rail, category switcher, view list,
  or command palette
- **AND** a category with no permitted, enabled child views is hidden

#### Scenario: A feature-flagged view is hidden when the flag is off

- **GIVEN** a view whose `feature_flag` is disabled for the deployment
- **WHEN** the Settings shell renders
- **THEN** that view does not appear in any navigation surface

#### Scenario: A deep-linked forbidden route is still denied at mount

- **GIVEN** a user who navigates directly to a route whose `permission` they lack
- **WHEN** the LiveView mounts
- **THEN** `Permit.Phoenix.LiveView.AuthorizeHook` denies access
- **AND** the same catalog permission key drives both the hidden nav entry and the mount denial

### Requirement: Active view resolves via deterministic longest-prefix URI match

The active view and category SHALL be resolved by an `on_mount` hook
(`Settings.ShellHook`) that reads the connection URI and calls
`Catalog.view_for_path/1`, which returns the view whose matching prefix is longest
across all views. The system SHALL NOT use hand-typed `current_path` strings or
per-view negated `String.starts_with?/2` denylists to determine active state. Every
canonical Settings route SHALL be deep-linkable and bookmarkable, and merged legacy
`/admin/*` routes SHALL redirect to their canonical `/settings/*` targets rather than
returning 404.

#### Scenario: Shared URI root resolves to the correct view

- **GIVEN** a view `Sweep Profiles` at `/settings/networks` and a view `BGP / BMP` at
  `/settings/networks/bmp`
- **WHEN** the user navigates to `/settings/networks/bmp`
- **THEN** `view_for_path/1` selects the BGP / BMP view because its prefix is longest
- **AND** navigating to `/settings/networks` selects Sweep Profiles

#### Scenario: A new nested route needs no denylist update

- **GIVEN** a new view added at `/settings/networks/foo`
- **WHEN** the user navigates to `/settings/networks/foo`
- **THEN** the active view is resolved by longest-prefix match alone
- **AND** no per-view denylist is created or edited

#### Scenario: A deep link resolves the active view and breadcrumbs

- **WHEN** a user opens a canonical Settings route directly by URL
- **THEN** the shell highlights the matching view and category and renders breadcrumbs
  `Settings > Category > View`

#### Scenario: A merged admin route redirects

- **WHEN** a user opens a merged legacy route such as `/admin/cluster`
- **THEN** the request redirects to the canonical `/settings/cluster` route

### Requirement: Ctrl+K command palette jumps to any permitted view

The Settings shell SHALL provide a command palette opened with Ctrl+K that fuzzy-filters
`Catalog.palette_index/1` (category title, view title, route, icon, keywords) over the
views the user is permitted to see, and navigates to the selected view's route on Enter.
The palette SHALL be keyboard-accessible: focus trap, ESC to close, arrow-key roving,
and restore focus on close.

#### Scenario: Fuzzy search and jump

- **GIVEN** a user with permission to view `Cluster Status`
- **WHEN** the user presses Ctrl+K and types a matching keyword
- **THEN** the palette lists the matching view
- **AND** pressing Enter navigates to that view's route

#### Scenario: Palette omits unpermitted views

- **GIVEN** a user lacking permission for a view
- **WHEN** the user opens the palette and searches for it
- **THEN** that view does not appear in the palette results

### Requirement: Per-user Original-UI toggle enables phased migration

A per-user `settings_ui` preference (`:original | :catalog`) SHALL control whether a
user sees the legacy Settings chrome or the new catalog-driven shell, defaulting to
`:original` until the cutover. During migration the legacy tab bar SHALL be fed from
the same catalog through a thin adapter, so exactly one source of truth exists in both
chromes before the visual cutover.

#### Scenario: Default users keep the legacy chrome

- **GIVEN** a user with `settings_ui: :original`
- **WHEN** they open a Settings page
- **THEN** they see the legacy Settings chrome unchanged
- **AND** the `Settings.ShellHook` is a no-op for that user

#### Scenario: Opt-in users see the new shell

- **GIVEN** a user with `settings_ui: :catalog`
- **WHEN** they open a migrated Settings category
- **THEN** they see the new catalog-driven shell

#### Scenario: One source of truth during migration

- **GIVEN** a new view added to the catalog mid-migration
- **WHEN** both chromes are rendered
- **THEN** the view appears in the legacy tab bar (via the adapter) and the new shell
  without duplicating navigation data
